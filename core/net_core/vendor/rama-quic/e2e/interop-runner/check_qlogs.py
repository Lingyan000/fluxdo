"""Validate complete Rama JSON text sequences without loading entire traces."""
import json
from pathlib import Path

from check_results import InvalidResults, unique_object

MAX_RECORD_BYTES = 8 * 1024 * 1024
MAX_TRACE_BYTES = 256 * 1024 * 1024


def check_qlog(path, *, role=None):
    records = 0
    closed = 0
    active = set()

    def reject_constant(value):
        raise InvalidResults(f"invalid JSON constant {value}")

    def consume(record):
        nonlocal records, closed
        if len(record) > MAX_RECORD_BYTES:
            raise InvalidResults("qlog record exceeds 8 MiB")
        if not record.endswith(b"\n"):
            raise InvalidResults("qlog record is truncated (missing newline terminator)")
        try:
            event = json.loads(record.decode("utf-8"), object_pairs_hook=unique_object,
                               parse_constant=reject_constant)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise InvalidResults(f"invalid qlog JSON record {records + 1}: {error}") from error
        if not isinstance(event, dict):
            raise InvalidResults("qlog record must be an object")
        if records == 0 and (event.get("file_schema") != "urn:ietf:params:qlog:file:sequential"
                             or event.get("serialization_format") != "application/qlog+json-seq"):
            raise InvalidResults("missing Rama sequential qlog header")
        name = event.get("name")
        if role == "server" and name in {"quic:connection_started", "quic:connection_closed"}:
            group = event.get("group_id")
            if not isinstance(group, str) or not group:
                raise InvalidResults("server connection event has no group_id")
            # Expiry permits a new allocation for the same original DCID. Two
            # live allocations for it would instead duplicate connection state.
            if name == "quic:connection_started":
                if group in active:
                    raise InvalidResults(f"overlapping server connections for {group}")
                active.add(group)
            else:
                active.discard(group)
        closed += name == "quic:connection_closed"
        records += 1

    with Path(path).open("rb") as source:
        if source.read(1) != b"\x1e":
            raise InvalidResults("qlog must begin with a JSON sequence record separator")
        pending = b""
        total = 1
        while chunk := source.read(64 * 1024):
            total += len(chunk)
            if total > MAX_TRACE_BYTES:
                raise InvalidResults("qlog exceeds 256 MiB validation limit")
            pieces = chunk.split(b"\x1e")
            pending += pieces[0]
            if len(pending) > MAX_RECORD_BYTES:
                raise InvalidResults("qlog record exceeds 8 MiB")
            if len(pieces) > 1:
                consume(pending)
                for record in pieces[1:-1]:
                    consume(record)
                pending = pieces[-1]
        consume(pending)
    if not closed:
        raise InvalidResults("qlog has no quic:connection_closed event")
    return {"records": records, "connection_closed_events": closed, "bytes": total}


def gate_qlogs(artifacts, *, role, peers, cases, optional=frozenset()):
    checked = {}
    failures = []
    for peer in peers:
        pair = f"{peer}_rama" if role == "client" else f"rama_{peer}"
        for case in cases:
            # A peer that does not implement this testcase produces no run and so no qlog; its
            # absence is tolerated exactly where its `unsupported` result is (see `gate`).
            if (peer, case) in optional:
                continue
            relative = Path(f"logs-rama-{role}") / pair / case / role / "qlog" / f"rama-{role}.sqlog"
            try:
                checked[str(relative)] = check_qlog(Path(artifacts) / relative, role=role)
                # Protocol checks must never be replaced by an unsupported result
                # caused by missing TLS decryption material.
                keys = Path(artifacts) / relative.parent.parent / "keys.log"
                if not keys.read_text().strip():
                    raise InvalidResults("empty Rama TLS keylog")
            except (InvalidResults, OSError) as error:
                failures.append(f"{relative}: {error}")
    if failures:
        raise InvalidResults("required Rama qlogs are incomplete:\n" + "\n".join(failures))
    return checked
