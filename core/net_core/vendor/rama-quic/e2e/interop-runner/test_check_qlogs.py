import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_qlogs import check_qlog, gate_qlogs
from check_results import InvalidResults


def sequence(*events):
    return b"".join(b"\x1e" + json.dumps(event).encode() + b"\n" for event in events)


HEADER = {"file_schema": "urn:ietf:params:qlog:file:sequential",
          "serialization_format": "application/qlog+json-seq"}
STARTED = {"name": "quic:connection_started", "group_id": "attempt", "data": {}}
CLOSED = {"name": "quic:connection_closed", "group_id": "attempt", "data": {}}


class QlogGateTests(unittest.TestCase):
    def test_complete_sequence_and_chunk_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.sqlog"
            path.write_bytes(sequence(HEADER, {"name": "quic:packet_sent", "data": "x" * 70000}, CLOSED))
            self.assertEqual(check_qlog(path)["records"], 3)
            self.assertEqual(check_qlog(path)["connection_closed_events"], 1)

    def test_server_allows_sequential_recreation_but_rejects_overlapping_lifetimes(self):
        other_start = {**STARTED, "group_id": "other"}
        other_close = {**CLOSED, "group_id": "other"}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.sqlog"
            path.write_bytes(sequence(HEADER, STARTED, other_start, CLOSED, STARTED,
                                      other_close, CLOSED))
            self.assertEqual(check_qlog(path, role="server")["connection_closed_events"], 3)
            for events in [(STARTED, STARTED, CLOSED),
                           (STARTED, other_start, other_close, STARTED, CLOSED)]:
                with self.subTest(events=events):
                    path.write_bytes(sequence(HEADER, *events))
                    with self.assertRaisesRegex(InvalidResults, "overlapping server connections"):
                        check_qlog(path, role="server")
            for group in (None, "", []):
                path.write_bytes(sequence(HEADER, {**STARTED, "group_id": group}, CLOSED))
                with self.subTest(group=group), self.assertRaisesRegex(InvalidResults, "group_id"):
                    check_qlog(path, role="server")

    def test_reject_malformed_truncated_or_missing_close(self):
        good = sequence(HEADER, CLOSED)
        examples = [b"", good[:-1], good + b"\x1e{", good + b"\x1e{}",
                    sequence(HEADER), sequence(CLOSED), good[1:],
                    good + b"garbage\n", good + b"\x1e[]\n",
                    good + b'\x1e{"x":NaN}\n', good + b'\x1e{"x":1,"x":2}\n',
                    good + b'\x1e{"x":"\xff"}\n']
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.sqlog"
            for data in examples:
                with self.subTest(data=data):
                    path.write_bytes(data)
                    with self.assertRaises(InvalidResults):
                        check_qlog(path)
            path.unlink()
            with self.assertRaises(OSError):
                check_qlog(path)

    def test_reject_utf16_records_even_when_json_autodetects_them(self):
        encoded = b"".join(b"\x1e" + (json.dumps(event) + "\n").encode("utf-16-be")
                           for event in (HEADER, CLOSED))
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.sqlog"
            path.write_bytes(encoded)
            with self.assertRaises(InvalidResults):
                check_qlog(path)

    def test_validation_size_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.sqlog"
            path.write_bytes(sequence(HEADER, CLOSED))
            for constant in ("MAX_RECORD_BYTES", "MAX_TRACE_BYTES"):
                with self.subTest(constant=constant), patch("check_qlogs." + constant, 16):
                    with self.assertRaises(InvalidResults):
                        check_qlog(path)

    def test_every_expected_role_case_and_peer_is_required(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = []
            for role in ("client", "server"):
                for peer in ("quic-go", "ngtcp2"):
                    pair = f"{peer}_rama" if role == "client" else f"rama_{peer}"
                    for case in ("handshake", "retry"):
                        path = root / f"logs-rama-{role}" / pair / case / role / "qlog" / f"rama-{role}.sqlog"
                        path.parent.mkdir(parents=True)
                        path.write_bytes(sequence(HEADER, CLOSED))
                        (path.parent.parent / "keys.log").write_text("CLIENT_HANDSHAKE_TRAFFIC_SECRET test\n")
                        paths.append((role, path))
                self.assertEqual(len(gate_qlogs(root, role=role, peers=["quic-go", "ngtcp2"],
                                                cases=["handshake", "retry"])), 4)
            for role, path in paths:
                with self.subTest(path=path):
                    path.unlink()
                    with self.assertRaises(InvalidResults):
                        gate_qlogs(root, role=role, peers=["quic-go", "ngtcp2"], cases=["handshake", "retry"])
                    path.write_bytes(sequence(HEADER, CLOSED))

    def test_tls_keylog_is_required_and_nonempty(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            endpoint = root / "logs-rama-client/ngtcp2_rama/handshake/client"
            path = endpoint / "qlog/rama-client.sqlog"
            path.parent.mkdir(parents=True)
            path.write_bytes(sequence(HEADER, CLOSED))
            for content in (None, "", " \n\t"):
                if content is not None:
                    (endpoint / "keys.log").write_text(content)
                with self.subTest(content=content), self.assertRaises(InvalidResults):
                    gate_qlogs(root, role="client", peers=["ngtcp2"], cases=["handshake"])


if __name__ == "__main__":
    unittest.main()
