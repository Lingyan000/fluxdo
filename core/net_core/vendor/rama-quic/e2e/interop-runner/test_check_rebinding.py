"""ACK-first evidence must not hide missing validation or a failed transfer."""
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_migration import PINNED_PEERS
from check_rebinding import SERVER, verify_rebinding, verify_rebinding_packets
from check_results import InvalidResults, gate
from run_interop import check_runner_exit, migration_classifications
from test_check_migration import packet

CLIENT = ("193.167.0.100", 40000)
NAT1 = (CLIENT[0], 41000)
NAT2 = (CLIENT[0], 42000)
A, B, OLD = "0123456789abcdef", "1123456789abcdef", "2123456789abcdef"
EXITS = dict(client="rama", server="ngtcp2", case="rebind-port", client_exit=0, server_exit=137)
KEY = ("rama", "ngtcp2", "rebind-port")
REPORT = dict(clients=["rama"], servers=["ngtcp2"], tests={"BP": {"name": "rebind-port"}},
              results=[[dict(name="rebind-port", abbr="BP", result="failed")]])


def traces():
    server = [
        packet(1, CLIENT, SERVER, scids=("client",), versions=(1,), long_types=(0,), frames=(6,)),
        packet(2, SERVER, CLIENT, scids=("server",), versions=(1,), long_types=(0,), frames=(6,)),
        packet(3, NAT1, SERVER, frames=(2,)),
        packet(4, SERVER, NAT1, frames=(3, 0)),
        packet(5, SERVER, NAT1, challenges=(A,), frames=(0x1a,)),
        packet(6, NAT1, SERVER, responses=(A,), frames=(0x1b,)),
        packet(7, SERVER, NAT1, frames=(0x0e,)),
        packet(8, NAT2, SERVER, frames=(2,)),
        packet(9, SERVER, NAT2, challenges=(B,), frames=(0x1a,)),
        packet(10, NAT2, SERVER, responses=(B,), frames=(0x1b,)),
        packet(11, SERVER, NAT2, frames=(0x0e,)),
        packet(12, SERVER, NAT1, challenges=(OLD,), frames=(0x1a,)),
    ]
    for p in server:
        p["number"] *= 10
    server.extend([packet(65, NAT1, SERVER, frames=(2,)), packet(105, NAT2, SERVER, frames=(2,))])
    server.sort(key=lambda p: p["number"])
    client = copy.deepcopy(server[:-1])
    for p in client:
        p["src" if p["dst"] == SERVER else "dst"] = CLIENT
    return client, server


def at(trace, index):
    return next(p for p in trace if p["number"] == (index + 1) * 10)


def lost_probe_traces():
    client, server = traces()
    # A first probe is lost between captures; a fresh token validates NAT2.
    client[:] = [p for p in client if p["number"] not in (90, 100)]
    server[:] = [p for p in server if p["number"] != 100]
    replacement = "3123456789abcdef"
    server.extend([packet(95, SERVER, NAT2, challenges=(replacement,), frames=(0x1a,)),
                   packet(100, NAT2, SERVER, responses=(replacement,), frames=(0x1b,))])
    client.extend([packet(95, SERVER, CLIENT, challenges=(replacement,), frames=(0x1a,)),
                   packet(100, CLIENT, SERVER, responses=(replacement,), frames=(0x1b,))])
    for trace in (client, server):
        trace.sort(key=lambda p: p["number"])
    return client, server


class RebindingEvidenceTests(unittest.TestCase):
    def test_ack_prefix_is_verified_without_retry(self):
        proof = verify_rebinding_packets(*traces())
        self.assertEqual(proof["classification"], "checker-incompatible")
        self.assertEqual([p["ack_prefix_packets"] for p in proof["paths"]], [1, 0])
        self.assertEqual(proof["server_challenges_answered"], 2)
        self.assertEqual([p["token"] for p in proof["undelivered_obsolete_path_probes"]], [OLD])

    def test_lost_first_probe_needs_later_validation_on_the_same_path(self):
        client, server = lost_probe_traces()
        replacement = "3123456789abcdef"
        proof = verify_rebinding_packets(client, server, lost_challenges={B})
        self.assertEqual(proof["undelivered_replaced_path_probes"], [
            dict(token=B, path=NAT2, sent_at=90, replacement=replacement, validated_at=100)])
        with self.assertRaises(InvalidResults):
            verify_rebinding_packets(client, server)
        for tokens in ({A}, {OLD}, {"ffffffffffffffff"}):
            with self.subTest(tokens=tokens), self.assertRaises(InvalidResults):
                verify_rebinding_packets(client, server, lost_challenges=tokens)
        mutations = {
            "probe actually delivered": lambda c, s: c.insert(8, packet(90, SERVER, CLIENT, challenges=(B,), frames=(0x1a,))),
            "replacement not delivered": lambda c, s: c.remove(next(p for p in c if p["number"] == 95)),
            "replacement unanswered": lambda c, s: at(c, 9).update(responses=(), frames=(0,)),
            "response lost": lambda c, s: at(s, 9).update(responses=(), frames=(0,)),
            "wrong path": lambda c, s: at(s, 9).update(src=NAT1),
            "no data after validation": lambda c, s: at(s, 10).update(frames=(2,)),
            "no client progress": lambda c, s: s.remove(next(p for p in s if p["number"] == 105)),
        }
        for name, mutate in mutations.items():
            c, s = copy.deepcopy((client, server))
            mutate(c, s)
            with self.subTest(name=name), self.assertRaises(InvalidResults):
                verify_rebinding_packets(c, s, lost_challenges={B})

    def test_lost_probe_console_requires_matching_capture_and_transfer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "logs-rama-client/ngtcp2_rama/rebind-port"
            for folder in ("client", "server_www", "client_downloads"):
                (directory / folder).mkdir(parents=True)
            (directory / "client/keys.log").write_text("keys")
            for folder in ("server_www", "client_downloads"):
                (directory / folder / "payload").write_bytes(b"x" * (10 * 1024 * 1024))
            token = ":".join(B[i:i + 2] for i in range(0, len(B), 2))
            output = directory / "output.txt"
            message = f"2026-11-02 18:03:43,773 PATH_CHALLENGE without a PATH_RESPONSE: {[token]!r}"
            output.write_text("Check of downloaded files succeeded.\n" + message + "\n" + message)
            with patch("check_rebinding.read_packets", side_effect=lost_probe_traces()):
                proof = verify_rebinding(root, "client", "ngtcp2", EXITS, peer_image=PINNED_PEERS["ngtcp2"])
            self.assertEqual(proof["undelivered_replaced_path_probes"][0]["token"], B)
            self.assertEqual(proof["bytes"], 10 * 1024 * 1024)
            # Each console failure needs its own capture proof. A proven lost
            # probe must not stand in for an unproven ACK-first report.
            both = ("Check of downloaded files succeeded.\n" + message + "\n"
                    "First server packet on new path tuple did not contain a PATH_CHALLENGE frame")
            output.write_text(both)
            with patch("check_rebinding.read_packets", side_effect=lost_probe_traces()):
                verify_rebinding(root, "client", "ngtcp2", EXITS, peer_image=PINNED_PEERS["ngtcp2"])
            client, server = lost_probe_traces()
            for trace in (client, server):
                trace[:] = [p for p in trace if p["number"] != 40]
            # Lost-probe-only evidence is valid even with no ACK prefix.
            proof = verify_rebinding_packets(client, server, lost_challenges={B})
            self.assertEqual([p["ack_prefix_packets"] for p in proof["paths"]], [0, 0])
            with patch("check_rebinding.read_packets", side_effect=(client, server)):
                with self.assertRaisesRegex(InvalidResults, "ACK-first failure has no capture proof"):
                    verify_rebinding(root, "client", "ngtcp2", EXITS, peer_image=PINNED_PEERS["ngtcp2"])
            for report in ("[]", "['invalid']", repr([B]), "None", "not a literal"):
                output.write_text("Check of downloaded files succeeded.\nPATH_CHALLENGE without a PATH_RESPONSE: " + report)
                with self.subTest(report=report), self.assertRaises(InvalidResults):
                    verify_rebinding(root, "client", "ngtcp2", EXITS, peer_image=PINNED_PEERS["ngtcp2"])
            output.write_text("Check of downloaded files succeeded.\n" + message)
            (directory / "client_downloads/payload").write_bytes(b"y" * (10 * 1024 * 1024))
            with patch("check_rebinding.read_packets", side_effect=lost_probe_traces()), self.assertRaises(InvalidResults):
                verify_rebinding(root, "client", "ngtcp2", EXITS, peer_image=PINNED_PEERS["ngtcp2"])

    def test_validation_may_follow_multiple_ack_datagrams(self):
        client, server = traces()
        for trace in (client, server):
            trace.insert(4, dict(trace[3], number=45))
        self.assertEqual(verify_rebinding_packets(client, server)["paths"][0]["ack_prefix_packets"], 2)

    def test_address_rebinding_requires_changed_ip_and_keeps_path_specific_responses(self):
        client, server = traces()
        replacements = {NAT1: ("193.167.0.71", NAT1[1]), NAT2: ("193.167.0.224", NAT2[1])}
        with self.assertRaisesRegex(InvalidResults, "client IP changes"):
            verify_rebinding_packets(client, server, address_rebinding=True)
        for p in server:
            p["src"] = replacements.get(p["src"], p["src"])
            p["dst"] = replacements.get(p["dst"], p["dst"])
        self.assertEqual(len(verify_rebinding_packets(client, server, address_rebinding=True)["paths"]), 2)
        with self.assertRaisesRegex(InvalidResults, "client IP changes"):
            verify_rebinding_packets(client, server)
        at(server, 5)["src"] = replacements[NAT2]
        with self.assertRaises(InvalidResults):
            verify_rebinding_packets(client, server, address_rebinding=True)

    def test_long_ack_prefix_and_missing_client_progress_fail(self):
        client, server = traces()
        server[4:4] = [dict(server[3], number=n) for n in (41, 42, 43, 44)]
        with self.assertRaisesRegex(InvalidResults, "ACK prefix"):
            verify_rebinding_packets(client, server)
        client, server = traces()
        server[:] = [p for p in server if p["number"] != 65]
        with self.assertRaisesRegex(InvalidResults, "non-probing progress"):
            verify_rebinding_packets(client, server)

    def test_each_missing_or_corrupted_invariant_fails_closed(self):
        mutations = {
            "empty client": lambda c, s: c.clear(),
            "wrong endpoint": lambda c, s: at(s, 3).update(src=(SERVER[0], 444)),
            "undecoded ACK": lambda c, s: at(s, 3).update(frames=()),
            "incomplete challenge": lambda c, s: at(s, 4).update(challenges=()),
            "incomplete response": lambda c, s: at(c, 5).update(responses=()),
            "invalid token": lambda c, s: at(s, 4).update(challenges=("invalid",)),
            "missing server challenge": lambda c, s: at(s, 4).update(challenges=(), frames=(0,)),
            "missing response delivery": lambda c, s: at(s, 5).update(responses=(), frames=(0,)),
            "missing client response": lambda c, s: at(c, 5).update(responses=(), frames=(0,)),
            "wrong-path response": lambda c, s: at(s, 5).update(src=CLIENT),
            "wrong-token response": lambda c, s: at(s, 5).update(responses=(OLD,)),
            "response before challenge": lambda c, s: at(c, 4).update(challenges=(), responses=(A,), frames=(0x1b,)),
            "challenge not delivered": lambda c, s: at(c, 4).update(challenges=(), frames=(0,)),
            "unsent challenge": lambda c, s: at(c, 4).update(challenges=(OLD,)),
            "no later server data": lambda c, s: at(s, 6).update(frames=(2,)),
            "no later client data": lambda c, s: (at(c, 6).update(frames=(2,)), at(c, 10).update(frames=(2,))),
            "data before challenge": lambda c, s: at(s, 3).update(frames=(0x0e,)),
            "unknown prefix frame": lambda c, s: at(s, 3).update(frames=(0x30,)),
            "server-first path": lambda c, s: at(s, 2).update(src=CLIENT),
            "client port change": lambda c, s: at(c, 2).update(src=NAT1),
            "client wrong destination": lambda c, s: at(c, 3).update(dst=NAT1),
            "two handshakes": lambda c, s: at(s, 6).update(scids=("other",), versions=(1,), long_types=(0,)),
            "mismatched handshakes": lambda c, s: at(c, 1).update(scids=("other",)),
            "wrong version": lambda c, s: at(s, 1).update(versions=(2,)),
            "reused probe token": lambda c, s: at(s, 8).update(challenges=(A,)),
            "extra server path": lambda c, s: s[-1].update(dst=(CLIENT[0], 50000)),
            "lost active-path probe": lambda c, s: s[-1].update(dst=NAT2),
            "delivered obsolete probe": lambda c, s: c.append(dict(s[-1], dst=CLIENT)),
            "old probe before migration": lambda c, s: (s.insert(8, dict(s[-1], number=75)), s.pop()),
            "out of order capture": lambda c, s: c.reverse(),
            "client-initiated validation": lambda c, s: at(c, 2).update(challenges=(OLD,), frames=(0x1a,)),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                client, server = traces()
                mutate(client, server)
                with self.assertRaises(InvalidResults):
                    verify_rebinding_packets(client, server)

    def test_no_rebinding_or_no_ack_first_limitation_is_not_classified(self):
        client, server = traces()
        with self.assertRaisesRegex(InvalidResults, "no port rebinding"):
            verify_rebinding_packets(client[:2], server[:2])
        for trace in (client, server):
            del trace[3]
        with self.assertRaisesRegex(InvalidResults, "ACK-first"):
            verify_rebinding_packets(client, server)

    def test_path_response_cannot_validate_another_tuple(self):
        client, server = traces()
        token = "3123456789abcdef"
        server.extend([packet(55, SERVER, NAT1, challenges=(token,), frames=(0x1a,)),
                       packet(85, NAT2, SERVER, responses=(token,), frames=(0x1b,))])
        client.extend([packet(55, SERVER, CLIENT, challenges=(token,), frames=(0x1a,)),
                       packet(57, CLIENT, SERVER, responses=(token,), frames=(0x1b,))])
        for trace in (client, server):
            trace.sort(key=lambda p: p["number"])
        with self.assertRaisesRegex(InvalidResults, "wrong path"):
            verify_rebinding_packets(client, server)

    def test_client_migration_is_not_nat_rebinding(self):
        client, server = traces()
        at(client, 9)["src"] = (CLIENT[0], CLIENT[1] + 1)
        with self.assertRaisesRegex(InvalidResults, "client changed its local endpoint"):
            verify_rebinding_packets(client, server)

    def test_pinned_pair_and_successful_exits_required(self):
        for role, peer in (("server", "ngtcp2"), ("client", "quic-go")):
            with self.assertRaises(InvalidResults):
                verify_rebinding("unused", role, peer, EXITS, peer_image=PINNED_PEERS[peer])
        with self.assertRaisesRegex(InvalidResults, "digest"):
            verify_rebinding("unused", "client", "ngtcp2", EXITS, peer_image="unreviewed")
        for key in EXITS:
            with self.subTest(key=key), self.assertRaises(InvalidResults):
                verify_rebinding("unused", "client", "ngtcp2", {k: v for k, v in EXITS.items() if k != key},
                                 peer_image=PINNED_PEERS["ngtcp2"])
        for change in (dict(client_exit=1), dict(server_exit=1), dict(client_exit=False), dict(case="rebind-addr")):
            with self.subTest(change=change), self.assertRaises(InvalidResults):
                verify_rebinding("unused", "client", "ngtcp2", dict(EXITS, **change),
                                 peer_image=PINNED_PEERS["ngtcp2"])

    def test_full_verifier_gate_and_normal_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "logs-rama-client/ngtcp2_rama/rebind-port"
            for folder in ("client", "server_www", "client_downloads"):
                (directory / folder).mkdir(parents=True)
            (directory / "client/keys.log").write_text("keys")
            output = directory / "output.txt"
            output.write_text("Check of downloaded files succeeded.\nFirst server packet on new path tuple did not contain a PATH_CHALLENGE frame")
            for folder in ("server_www", "client_downloads"):
                (directory / folder / "payload").write_bytes(b"x" * (10 * 1024 * 1024))

            def classify():
                with patch("check_rebinding.read_packets", side_effect=traces()):
                    return migration_classifications(root, "client", REPORT, {KEY: EXITS}, PINNED_PEERS)

            verified, proofs = classify()
            self.assertEqual(verified, {KEY: "checker-incompatible"})
            self.assertEqual(proofs[0]["bytes"], 10 * 1024 * 1024)
            self.assertEqual(gate(REPORT, clients=["rama"], servers=["ngtcp2"], cases=["rebind-port"],
                                  verified_migrations=verified), 1)
            check_runner_exit(1, {"returned": 1}, verified)
            self.assertEqual(REPORT["results"][0][0]["result"], "failed")
            with self.assertRaises(InvalidResults):
                gate(REPORT, clients=["rama"], servers=["ngtcp2"], cases=["rebind-port"])
            with self.assertRaises(InvalidResults):
                check_runner_exit(1, None, verified)
            with self.assertRaises(InvalidResults):
                check_runner_exit(2, {"returned": 2}, verified)
            address_report = copy.deepcopy(REPORT)
            address_report["tests"]["BP"]["name"] = "rebind-addr"
            address_report["results"][0][0]["name"] = "rebind-addr"
            address_key = ("rama", "ngtcp2", "rebind-addr")
            address_directory = directory.with_name("rebind-addr")
            directory.rename(address_directory)
            c, s = traces()
            for p in s:
                for field in ("src", "dst"):
                    if p[field] == NAT1:
                        p[field] = ("193.167.0.71", NAT1[1])
                    elif p[field] == NAT2:
                        p[field] = ("193.167.0.224", NAT2[1])
            with patch("check_rebinding.read_packets", side_effect=(c, s)):
                address_verified, _ = migration_classifications(
                    root, "client", address_report, {address_key: dict(EXITS, case="rebind-addr")}, PINNED_PEERS)
            self.assertEqual(address_verified, {address_key: "checker-incompatible"})
            self.assertEqual(gate(address_report, clients=["rama"], servers=["ngtcp2"], cases=["rebind-addr"],
                                  verified_migrations=address_verified), 1)
            address_directory.rename(directory)
            for peer in ("quic-go",):
                report = copy.deepcopy(REPORT)
                report["servers"] = [peer]
                with self.assertRaises(InvalidResults):
                    gate(report, clients=["rama"], servers=[peer], cases=["rebind-port"],
                         verified_migrations={("rama", peer, "rebind-port"): "checker-incompatible"})

            with patch("check_migration.subprocess.run", side_effect=subprocess.CalledProcessError(1, "tshark")):
                failed, proofs = migration_classifications(root, "client", REPORT, {KEY: EXITS}, PINNED_PEERS)
            self.assertEqual(failed, {})
            self.assertIn("could not be decoded", proofs[0]["error"])
            for content in ("unrelated failure", output.read_text() + "\nPATH_CHALLENGE without a PATH_RESPONSE"):
                output.write_text(content)
                self.assertEqual(classify()[0], {})
            output.write_text("Check of downloaded files succeeded.\nFirst server packet on new path tuple did not contain a PATH_CHALLENGE frame")
            (directory / "client_downloads/payload").write_bytes(b"y" * (10 * 1024 * 1024))
            self.assertEqual(classify()[0], {})
            for folder in ("server_www", "client_downloads"):
                (directory / folder / "payload").write_bytes(b"x" * 100)
            self.assertEqual(classify()[0], {})
