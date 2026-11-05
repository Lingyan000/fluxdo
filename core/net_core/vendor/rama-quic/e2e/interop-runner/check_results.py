#!/usr/bin/env python3
"""Fail-closed gate for the pinned QUIC interop runner's client-major matrix."""
import argparse
import json
from pathlib import Path


class InvalidResults(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidResults(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_report(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_object)


def gate(report, *, clients, servers, cases, optional=None, evidence=None, verified_migrations=None):
    """Require exactly one accounted outcome for every requested cell and case.

    `optional` maps (peer, case) to the endpoint roles allowed to exit 127.
    Every observed 127 needs that side's explicit exception and Docker exit evidence;
    an unsupported result without a 127 (e.g. missing TLS keys) always fails.
    `verified_migrations` contains only results from the independent path
    packet/file/exit verifier. They stay failed in upstream JSON and are counted
    separately from successes by the caller.
    """
    for label, expected in (("clients", clients), ("servers", servers), ("cases", cases)):
        if (not expected or not all(isinstance(x, str) and x for x in expected)
                or len(set(expected)) != len(expected)):
            raise InvalidResults(f"{label}: expected selection must be nonempty and unique")
    if not isinstance(report, dict):
        raise InvalidResults("report must be an object")
    for axis, expected in (("clients", clients), ("servers", servers)):
        actual = report.get(axis)
        if not isinstance(actual, list) or not all(isinstance(x, str) for x in actual):
            raise InvalidResults(f"invalid {axis}")
        if len(actual) != len(set(actual)) or set(actual) != set(expected):
            raise InvalidResults(f"{axis}: expected {expected}, got {actual}")
    definitions = report.get("tests")
    if not isinstance(definitions, dict):
        raise InvalidResults("missing test definitions")
    names = []
    for abbr, definition in definitions.items():
        if not isinstance(definition, dict) or not isinstance(definition.get("name"), str):
            raise InvalidResults(f"invalid test definition {abbr}")
        names.append(definition["name"])
    if len(names) != len(set(names)) or set(names) != set(cases):
        raise InvalidResults(f"test definitions do not match selected cases: {names}")
    cells = report.get("results")
    if not isinstance(cells, list) or len(cells) != len(clients) * len(servers):
        raise InvalidResults("missing or extra matrix cells")
    failures = []
    count = 0
    for ci, client in enumerate(report["clients"]):
        for si, server in enumerate(report["servers"]):
            cell = cells[ci * len(servers) + si]
            label = f"client={client} server={server}"
            if not isinstance(cell, list):
                raise InvalidResults(f"{label}: invalid cell")
            seen = set()
            for entry in cell:
                if not isinstance(entry, dict):
                    raise InvalidResults(f"{label}: invalid result")
                name = entry.get("name")
                abbr = entry.get("abbr")
                if not isinstance(name, str) or name not in cases or name in seen:
                    raise InvalidResults(f"{label}: unexpected or duplicate case {name!r}")
                if not isinstance(abbr, str) or definitions.get(abbr, {}).get("name") != name:
                    raise InvalidResults(f"{label}: incorrect abbreviation for {name}")
                seen.add(name)
                result = entry.get("result")
                # Attribute every unsupported endpoint to an explicit role/case policy.
                peer = server if client == "rama" else client
                tolerated = False
                if result == "failed" and name == "connectionmigration":
                    classification = (verified_migrations or {}).get((client, server, name))
                    tolerated = classification == {
                        ("rama", "ngtcp2"): "checker-incompatible",
                        ("ngtcp2", "rama"): "checker-incompatible",
                        ("quic-go", "rama"): "peer-did-not-exercise",
                    }.get((client, server)) and classification is not None
                if (result == "failed" and (client, server) == ("rama", "ngtcp2")
                        and name in ("rebind-port", "rebind-addr")):
                    tolerated = (verified_migrations or {}).get((client, server, name)) == "checker-incompatible"
                if result == "unsupported" and (peer, name) in (optional or {}):
                    exits = (evidence or {}).get((client, server, name), {})
                    unsupported_sides = {side for side in ("client", "server")
                                         if exits.get(f"{side}_exit") == 127}
                    complete = all(type(exits.get(f"{side}_exit")) is int
                                   for side in ("client", "server"))
                    tolerated = (complete and bool(unsupported_sides)
                                 and unsupported_sides <= optional[(peer, name)])
                if result != "succeeded" and not tolerated:
                    failures.append(f"{label} case={name}: {result!r}")
                count += 1
            if seen != set(cases):
                raise InvalidResults(f"{label}: missing cases {sorted(set(cases) - seen)}")
    if failures:
        raise InvalidResults("required outcomes were not successful:\n" + "\n".join(failures))
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--clients", required=True)
    parser.add_argument("--servers", required=True)
    parser.add_argument("--cases", required=True)
    args = parser.parse_args()
    try:
        count = gate(load_report(args.report), clients=args.clients.split(","),
                     servers=args.servers.split(","), cases=args.cases.split(","))
    except (InvalidResults, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"QUIC interop gate failed: {error}\n")
    print(f"QUIC interop gate passed: {count} required outcomes succeeded")


if __name__ == "__main__":
    main()
