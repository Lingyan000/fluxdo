"""Adversarial fixtures: an empty or partially successful run must never pass."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from check_results import InvalidResults, gate, load_report


class ResultGateTests(unittest.TestCase):
    def setUp(self):
        self.expected = dict(clients=["rama"], servers=["quic-go", "ngtcp2"],
                             cases=["handshake", "transfer", "retry"])
        self.report = {
            "clients": ["rama"], "servers": ["ngtcp2", "quic-go"],
            "tests": {abbr: {"name": name} for abbr, name in
                      zip(["H", "DC", "S"], self.expected["cases"])},
            "results": [[{"name": name, "abbr": abbr, "result": "succeeded"}
                         for abbr, name in zip(["H", "DC", "S"], self.expected["cases"])]
                        for _ in range(2)],
        }

    def test_http3_is_required_in_default_scope_and_both_roles(self):
        lock = json.loads(Path(__file__).with_name("runner.lock.json").read_text())
        self.assertIn("http3", lock["cases"])
        for role in ("client", "server"):
            expected = dict(clients=["rama"], servers=["ngtcp2", "quic-go"], cases=["http3"])
            if role == "server":
                expected.update(clients=["ngtcp2", "quic-go"], servers=["rama"])
            report = dict(clients=expected["clients"], servers=expected["servers"],
                          tests={"H3": {"name": "http3"}},
                          results=[[{"name": "http3", "abbr": "H3", "result": "succeeded"}]
                                   for _ in range(2)])
            self.assertEqual(gate(report, **expected, optional={("quic-go", "v2")}), 2)
            for result in ("unsupported", "failed"):
                for peer in range(2):
                    with self.subTest(role=role, result=result, peer=peer):
                        broken = copy.deepcopy(report)
                        broken["results"][peer][0]["result"] = result
                        with self.assertRaises(InvalidResults):
                            gate(broken, **expected, optional={("quic-go", "v2")})

    def test_complete_success_and_axis_order(self):
        self.assertEqual(gate(self.report, **self.expected), 6)

    def test_verified_migrations_have_exact_pair_and_classification(self):
        for client, server, classification in [("rama", "ngtcp2", "checker-incompatible"),
                                                 ("ngtcp2", "rama", "checker-incompatible"),
                                                 ("quic-go", "rama", "peer-did-not-exercise")]:
            report = dict(clients=[client], servers=[server], tests={"CM": {"name": "connectionmigration"}},
                          results=[[dict(name="connectionmigration", abbr="CM", result="failed")]])
            expected = dict(clients=[client], servers=[server], cases=["connectionmigration"])
            key = (client, server, "connectionmigration")
            with self.assertRaises(InvalidResults):
                gate(report, **expected)
            self.assertEqual(gate(report, **expected, verified_migrations={key: classification}), 1)
            with self.assertRaises(InvalidResults):
                gate(report, **expected, verified_migrations={key: "wrong"})
            report["results"][0][0]["result"] = "unsupported"
            with self.assertRaises(InvalidResults):
                gate(report, **expected, verified_migrations={key: classification})
        self.report["results"][0][0]["result"] = "failed"
        with self.assertRaises(InvalidResults):
            gate(self.report, **self.expected,
                 verified_migrations={("rama", "ngtcp2", "handshake"): "checker-incompatible"})

    def test_unsupported_requires_declared_side_and_actual_exit_127(self):
        self.report["results"][0][0]["result"] = "unsupported"
        policy = {("ngtcp2", "handshake"): {"server"}}
        for client_exit, server_exit, allowed in [(0, 127, True), (127, 0, False),
                                                   (0, 0, False), (127, 127, False),
                                                   (None, 127, False)]:
            with self.subTest(client_exit=client_exit, server_exit=server_exit):
                evidence = {("rama", "ngtcp2", "handshake"):
                            {"client_exit": client_exit, "server_exit": server_exit}}
                if allowed:
                    self.assertEqual(gate(self.report, **self.expected, optional=policy, evidence=evidence), 6)
                else:
                    with self.assertRaises(InvalidResults):
                        gate(self.report, **self.expected, optional=policy, evidence=evidence)
        with self.assertRaises(InvalidResults):
            gate(self.report, **self.expected, optional=policy)

    def test_declared_rama_limitation_and_overlapping_peer_limitation(self):
        self.report["results"][0][0]["result"] = "unsupported"
        evidence = {("rama", "ngtcp2", "handshake"): {"client_exit": 127, "server_exit": 127}}
        self.assertEqual(gate(self.report, **self.expected,
                              optional={("ngtcp2", "handshake"): {"client", "server"}}, evidence=evidence), 6)

    def test_both_roles_client_major_order(self):
        self.report["clients"], self.report["servers"] = ["ngtcp2", "quic-go"], ["rama"]
        self.expected.update(clients=["quic-go", "ngtcp2"], servers=["rama"])
        self.assertEqual(gate(self.report, **self.expected), 6)
        self.report["results"][1][2]["result"] = "failed"
        with self.assertRaisesRegex(InvalidResults, "client=quic-go server=rama case=retry"):
            gate(self.report, **self.expected)

    def test_missing_unsupported_and_wrong_success_values(self):
        for value in [None, "unsupported", "failed", "success", "SUCCEEDED", True, 0, {}, []]:
            with self.subTest(value=value):
                report = copy.deepcopy(self.report)
                report["results"][1][0]["result"] = value
                with self.assertRaises(InvalidResults):
                    gate(report, **self.expected)

    def test_malformed_and_incomplete_fixtures(self):
        mutations = [
            lambda r: r.clear(),
            lambda r: r.update(results=[]),
            lambda r: r["results"].pop(),
            lambda r: r["results"].append(r["results"][0]),
            lambda r: r["results"][0].pop(),
            lambda r: r["results"][0].append(r["results"][0][0]),
            lambda r: r["results"][0][0].pop("result"),
            lambda r: r["results"][0][0].update(name="unknown"),
            lambda r: r["results"][0][0].update(abbr="DC"),
            lambda r: r["results"][0][0].update(name=[]),
            lambda r: r.update(servers=["ngtcp2", "ngtcp2"]),
            lambda r: r.update(servers=["rama", "quic-go"]),
            lambda r: r.update(clients=[]),
            lambda r: r["tests"].pop("S"),
            lambda r: r["tests"].update(OTHER={"name": "retry"}),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                report = copy.deepcopy(self.report)
                mutate(report)
                with self.assertRaises(InvalidResults):
                    gate(report, **self.expected)

    def test_empty_or_duplicate_expected_scope(self):
        for axis in self.expected:
            for value in ([], [""], ["rama", "rama"]):
                with self.subTest(axis=axis, value=value):
                    expected = dict(self.expected, **{axis: value})
                    with self.assertRaises(InvalidResults):
                        gate(self.report, **expected)

    def test_reject_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "report.json"
            path.write_text('{"results": [], "results": []}')
            with self.assertRaises(InvalidResults):
                load_report(path)
            path.write_text('{"results":')
            with self.assertRaises(json.JSONDecodeError):
                load_report(path)
            path.unlink()
            with self.assertRaises(OSError):
                load_report(path)


if __name__ == "__main__":
    unittest.main()
