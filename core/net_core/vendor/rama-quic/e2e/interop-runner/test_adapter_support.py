import json
from pathlib import Path
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from adapter_support import copy_logs, count_client_hellos, run_with_completion
from check_results import InvalidResults
from run_interop import check_runner_exit, implementations_without_heuristics, role_timeout, unsupported_policy


class AdapterTests(unittest.TestCase):
    def test_completion_distinguishes_classified_failures_from_crashes(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "completed.json"
            for count in (0, 1, 2):
                self.assertEqual(run_with_completion(lambda: count, path), count)
                check_runner_exit(count, json.loads(path.read_text()), {i: "verified" for i in range(count)})
            path.unlink()
            def crash():
                raise RuntimeError("runner crashed")
            with self.assertRaises(RuntimeError):
                run_with_completion(crash, path)
            self.assertFalse(path.exists())
        for completion in ({}, {"returned": False}, {"returned": "1"}, {"returned": 0}, None):
            with self.subTest(completion=completion), self.assertRaises(InvalidResults):
                check_runner_exit(1, completion, {"migration": "verified"})
        for status, count in ((1, 0), (0, 1), (2, 1), (-15, 1), (124, 1)):
            with self.subTest(status=status, count=count), self.assertRaises(InvalidResults):
                check_runner_exit(status, {"returned": status}, {i: "verified" for i in range(count)})

    def test_only_the_exact_127_endpoint_may_have_no_logs(self):
        for code in (0, 1, 127, 137):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temp:
                runner = SimpleNamespace(_rama_evidence={"case": "test"}, _rama_evidence_dir=Path(temp))
                state = [{"State": {"Running": False, "ExitCode": code}}]
                failure = subprocess.CompletedProcess([], 1, b"Could not find the file /logs/. in container")
                with patch("adapter_support.subprocess.check_output", side_effect=["id\n", json.dumps(state)]), \
                     patch("adapter_support.subprocess.run", return_value=failure):
                    if code == 127:
                        copy_logs(runner, "client", SimpleNamespace(name=temp))
                    else:
                        with self.assertRaises(RuntimeError):
                            copy_logs(runner, "client", SimpleNamespace(name=temp))
                self.assertEqual(runner._rama_evidence["client_exit"], code)

    def test_auto_unsupported_disabled_for_every_selected_implementation(self):
        self.assertEqual(implementations_without_heuristics(["peer-one", "peer-two"]), "rama,peer-one,peer-two")

    def test_ci_groups_cover_all_cases_once(self):
        lock = json.loads(Path(__file__).with_name("runner.lock.json").read_text())
        selected = [case for group in lock["case_groups"].values() for case in group]
        self.assertEqual(len(selected), len(set(selected)))
        self.assertEqual(set(selected), set(lock["cases"]))
        self.assertEqual(len(selected), 22)
        for group in lock["case_groups"].values():
            self.assertLess(2 * role_timeout(group, 2) + 20 * 60, 130 * 60)

    def test_crypto_limits_only_apply_to_client(self):
        for backend in ("boring", "rustls-ring", "rustls-aws-lc"):
            policy = unsupported_policy("server", backend, ["ngtcp2"])
            self.assertNotIn(("ngtcp2", "chacha20"), policy)
            self.assertNotIn(("ngtcp2", "v2"), policy)
            self.assertNotIn(("ngtcp2", "chacha20"), unsupported_policy("client", backend, ["ngtcp2"]))


class HandshakeCountTests(unittest.TestCase):
    @staticmethod
    def initial(dcid, *, scid="", offsets=(), number=42):
        fields = SimpleNamespace(all_fields=[SimpleNamespace(get_default_value=lambda n=n: str(n))
                                             for n in offsets]) if offsets else None
        return SimpleNamespace(dcid=dcid, scid=scid, packet_number=number,
                               get_field=lambda name: fields if name == "crypto_offset" else None)

    def test_lost_server_state_does_not_duplicate_a_client_attempt(self):
        client = [self.initial("original", offsets=(0,)),
                  self.initial("original", offsets=(1037,)),
                  self.initial("original", offsets=(0,)),
                  self.initial("new-server", offsets=(0,))]
        server = [self.initial("", scid="expired-server"),
                  self.initial("", scid="new-server")]
        self.assertEqual(count_client_hellos(client, server, []), 1)

    def test_retry_and_new_connection_ids_are_not_extra_attempts(self):
        client = [self.initial("original", offsets=(0,)),
                  self.initial("retry", offsets=(0,)),
                  self.initial("server", offsets=(0,)),
                  self.initial("new-connection-id")]
        self.assertEqual(count_client_hellos(client, [self.initial("", scid="server")],
                                            [self.initial("", scid="retry")]), 1)

    def test_distinct_attempts_count_even_with_zero_length_client_scids(self):
        for attempts in (0, 1, 49, 50, 51):
            with self.subTest(attempts=attempts):
                client = [self.initial(f"original-{i}", offsets=(100, 0)) for i in range(attempts)]
                self.assertEqual(count_client_hellos(client, [], []), attempts)

    def test_ack_only_and_tail_fragments_are_not_client_hellos(self):
        client = [self.initial("ack-only"), self.initial("fragment", offsets=(1037,))]
        self.assertEqual(count_client_hellos(client, [], []), 0)

    def test_missing_client_hello_dcid_fails_closed(self):
        initial = self.initial("original", offsets=(0,))
        del initial.dcid
        with self.assertRaises(AttributeError):
            count_client_hellos([initial], [], [])
