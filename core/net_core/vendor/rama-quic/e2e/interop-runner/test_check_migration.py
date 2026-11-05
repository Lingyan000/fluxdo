"""Migration classifications require evidence beyond the upstream failure text."""
import copy
from pathlib import Path
import tempfile
import unittest
import subprocess
from unittest.mock import patch
from types import SimpleNamespace

from check_migration import (FIELDS, PINNED_PEERS, PREFERRED, InvalidResults, parse_packets,
                             read_packets, verify_files, verify_migration, verify_packets)
from check_results import gate
from run_interop import migration_classifications

ORIGINAL = ("193.167.100.100", 443)
PREFERRED_SERVER = ("193.167.100.100", 4433)
CLIENT = ("193.167.0.100", 40000)


def packet(number, src=CLIENT, dst=ORIGINAL, **overrides):
    result = dict(number=number, src=src, dst=dst, dcids=("original",), challenges=(), responses=(),
                  frames=(1,), preferred=(), preferred_cids=(), scids=(), versions=(),
                  long_types=(), tls_types=())
    result.update(overrides)
    return result


def traces():
    packets = [
        packet(1),
        packet(2, ORIGINAL, CLIENT, scids=("server",), versions=(1,), long_types=(0,)),
        packet(3, ORIGINAL, CLIENT, preferred=tuple(PREFERRED), preferred_cids=("preferred",), tls_types=(8,)),
        packet(4, dst=PREFERRED_SERVER, dcids=("preferred",), challenges=("a",), frames=(0x1a,)),
        packet(5, PREFERRED_SERVER, CLIENT, responses=("a",), frames=(0x1b,)),
        packet(6, dst=PREFERRED_SERVER, dcids=("preferred",)),
        packet(7, PREFERRED_SERVER, CLIENT, challenges=("b",), frames=(0x1a,)),
        packet(8, dst=PREFERRED_SERVER, dcids=("preferred",), responses=("b",), frames=(0x1b,)),
        packet(9, PREFERRED_SERVER, CLIENT, frames=(0x0f,)),
    ]
    return packets, copy.deepcopy(packets)


class MigrationEvidenceTests(unittest.TestCase):
    def test_tshark_failure_is_recorded_and_the_cell_still_fails(self):
        report = dict(clients=["rama"], servers=["ngtcp2"],
                      tests={"CM": {"name": "connectionmigration"}},
                      results=[[dict(name="connectionmigration", abbr="CM", result="failed")]])
        key = ("rama", "ngtcp2", "connectionmigration")
        evidence = {key: dict(client="rama", server="ngtcp2", case="connectionmigration",
                              client_exit=0, server_exit=137)}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "logs-rama-client/ngtcp2_rama/connectionmigration"
            (directory / "client").mkdir(parents=True)
            (directory / "output.txt").write_text("First server packet did not contain a PATH_CHALLENGE frame")
            (directory / "client/keys.log").write_text("test keys")
            with patch("check_migration.subprocess.run", side_effect=subprocess.CalledProcessError(1, "tshark")):
                verified, proofs = migration_classifications(root, "client", report, evidence, PINNED_PEERS)
            self.assertEqual(verified, {})
            self.assertIn("could not be decoded", proofs[0]["error"])
            with self.assertRaisesRegex(InvalidResults, "connectionmigration: 'failed'"):
                gate(report, clients=["rama"], servers=["ngtcp2"], cases=["connectionmigration"],
                     verified_migrations=verified)

    def test_verified_response_first_migration(self):
        self.assertEqual(verify_packets(*traces())["classification"], "checker-incompatible")

    def test_only_one_late_previous_path_probe_can_be_recorded_separately(self):
        client, server = traces()
        old = packet(10, ORIGINAL, CLIENT, challenges=("old",), frames=(0x1a,))
        client.append(old)
        server.append(copy.deepcopy(old))
        with self.assertRaises(InvalidResults):
            verify_packets(client, server)
        proof = verify_packets(client, server, allow_late_previous_path_probe=True)
        self.assertEqual(proof["unanswered_previous_path_challenges"][0]["token"], "old")
        for changes in ({"number": 5}, {"src": PREFERRED_SERVER}, {"challenges": ("old", "second")}):
            with self.subTest(changes=changes), self.assertRaises(InvalidResults):
                changed_client, changed_server = copy.deepcopy(client), copy.deepcopy(server)
                changed_client[-1].update(changes)
                changed_server[-1].update(changes)
                verify_packets(changed_client, changed_server, allow_late_previous_path_probe=True)
        with self.assertRaises(InvalidResults):
            verify_packets(client[:-1], server, allow_late_previous_path_probe=True)
        early_send = copy.deepcopy(server)
        early_send[-1]["number"] = 5
        with self.assertRaises(InvalidResults):
            verify_packets(client, early_send, allow_late_previous_path_probe=True)
        probing_client, probing_server = copy.deepcopy(client), copy.deepcopy(server)
        probing_client[5]["frames"] = probing_server[5]["frames"] = (0,)
        with self.assertRaises(InvalidResults):
            verify_packets(probing_client, probing_server, allow_late_previous_path_probe=True)

    def test_each_protocol_invariant_rejects_corruption(self):
        mutations = {
            "advertisement": lambda c, s: c[2].update(preferred=()),
            "encrypted extensions": lambda c, s: c[2].update(tls_types=()),
            "preferred CID": lambda c, s: c[2].update(preferred_cids=()),
            "reused DCID": lambda c, s: c[0].update(dcids=("preferred",)),
            "wrong preferred DCID": lambda c, s: c[3].update(dcids=("wrong",)),
            "first probe absent": lambda c, s: c[3].update(challenges=()),
            "streams before validation": lambda c, s: c[3].update(frames=(0x0f,)),
            "first response mismatched": lambda c, s: s[4].update(responses=("wrong",)),
            "unanswered client probe": lambda c, s: c[5].update(challenges=("unanswered",)),
            "unanswered server probe": lambda c, s: c[7].update(responses=()),
            "server did not challenge": lambda c, s: s[6].update(challenges=()),
            "non-probing too early": lambda c, s: s[4].update(frames=(0x1b, 0x02)),
            "no server stream": lambda c, s: c[8].update(frames=(0,)),
            "two handshakes": lambda c, s: s.append(packet(10, ORIGINAL, CLIENT, scids=("other",), versions=(1,), long_types=(0,))),
            "wrong QUIC version": lambda c, s: s[1].update(versions=(2,)),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                client, server = traces()
                mutate(client, server)
                with self.assertRaises(InvalidResults):
                    verify_packets(client, server)
        client, server = traces()
        with self.assertRaisesRegex(InvalidResults, "did not migrate"):
            verify_packets(client[:5], server)
        with self.assertRaisesRegex(InvalidResults, "no decrypted"):
            verify_packets([dict(p, frames=()) for p in client], server)

    def test_peer_nonexercise_requires_zero_preferred_packets_in_both_captures(self):
        client, server = traces()
        self.assertEqual(verify_packets(client[:3], server[:3], peer_did_not_exercise=True)
                         ["classification"], "peer-did-not-exercise")
        for c, s in [(client[:4], server[:3]), (client[:3], server[:5])]:
            with self.assertRaises(InvalidResults):
                verify_packets(c, s, peer_did_not_exercise=True)

    def test_tshark_excludes_icmp_and_malformed_rows_fail_closed(self):
        row = [""] * len(FIELDS)
        row[0], row[1], row[3], row[4], row[6] = "1", CLIENT[0], "40000", ORIGINAL[0], "443"
        with patch("check_migration.subprocess.run", return_value=SimpleNamespace(stdout="\t".join(row))) as run:
            self.assertEqual(len(read_packets("capture", "keys")), 1)
            self.assertIn("quic && !icmp && !icmpv6", run.call_args.args[0])
        row[1] = "fd00:cafe:cafe::100,fd00:cafe:cafe:100::100"
        with self.assertRaises(InvalidResults):
            parse_packets("\t".join(row))
        with self.assertRaises(InvalidResults):
            parse_packets("\t".join(row[:-1]))

    def test_pin_and_exit_evidence_required_before_reading_captures(self):
        exits = dict(client="rama", server="ngtcp2", case="connectionmigration", client_exit=0, server_exit=137)
        with self.assertRaisesRegex(InvalidResults, "digest"):
            verify_migration("unused", "client", "ngtcp2", exits, peer_image="changed")
        for key in exits:
            with self.subTest(key=key):
                missing = {k: v for k, v in exits.items() if k != key}
                with self.assertRaises(InvalidResults):
                    verify_migration("unused", "client", "ngtcp2", missing, peer_image=PINNED_PEERS["ngtcp2"])

    def test_exact_file_workload_and_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("server_www", "client_downloads"):
                (root / name).mkdir()
                (root / name / "payload").write_bytes(b"x" * (2 * 1024 * 1024))
            self.assertEqual(verify_files(root)["bytes"], 2 * 1024 * 1024)
            (root / "client_downloads/payload").write_bytes(b"y" * (2 * 1024 * 1024))
            with self.assertRaisesRegex(InvalidResults, "bytes differ"):
                verify_files(root)
            (root / "client_downloads/payload").rename(root / "client_downloads/wrong")
            with self.assertRaisesRegex(InvalidResults, "filename"):
                verify_files(root)
