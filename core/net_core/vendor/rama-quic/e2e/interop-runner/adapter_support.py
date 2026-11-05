"""Upstream compatibility fixes and Docker-inspected exit provenance."""
import json
import logging
from pathlib import Path
import shutil
import subprocess


HANDSHAKE_COUNTER_SOURCE = (
    "https://github.com/quic-interop/quic-interop-runner/pull/509/commits/"
    "f1aff90f0db1f8a8166f7459427f91a49e7e6564"
)


def count_client_hellos(client_initials, server_initials, server_retries):
    """Upstream #509: count attempts, including lost/recreated server state, once."""
    # ClientHello retransmissions use the original DCID until a server Initial
    # or Retry arrives. Exclude those server-selected IDs and ACK-only Initials
    # sent to NEW_CONNECTION_ID values. Client SCIDs can be zero-length, and
    # Initial packet numbers need not start at zero.
    server_chosen = {getattr(packet, "scid", "")
                     for packet in [*server_initials, *server_retries]}
    client_chosen = set()
    for packet in client_initials:
        offsets = packet.get_field("crypto_offset")
        if offsets is not None and any(field.get_default_value() == "0"
                                       for field in offsets.all_fields):
            client_chosen.add(packet.dcid)
    return len(client_chosen - server_chosen)


def run_with_completion(main, completion):
    """Record a normal upstream return, never an exception or process interruption."""
    status = main()
    Path(completion).write_text(json.dumps({"returned": status}) + "\n")
    return status


def copy_logs(self, container, directory):
    # Compose resolves the service within this invocation's project. Upstream's
    # global `docker ps | awk` lookup would copy another run's named container.
    base = ["docker", "compose", "--env-file", "empty.env"]
    ids = subprocess.check_output(base + ["ps", "--all", "--quiet", container], text=True).split()
    if len(ids) != 1:
        raise RuntimeError(f"expected one {container} container, found {ids}")
    state = json.loads(subprocess.check_output(["docker", "inspect", ids[0]], text=True))[0]["State"]
    if state["Running"]:
        raise RuntimeError(f"{container} still running during result collection")
    evidence = getattr(self, "_rama_evidence", None)
    if evidence is not None:
        evidence[f"{container}_exit"] = state["ExitCode"]
    result = subprocess.run(
        ["docker", "compose", "--env-file", "empty.env", "cp",
         f"{container}:/logs/.", directory.name],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
    )
    if result.returncode:
        # Unsupported endpoints may exit before creating /logs. Only an actual
        # 127 permits that absence; a missing successful/failed run's logs is fatal.
        if state["ExitCode"] == 127 and b"Could not find the file /logs/." in result.stdout:
            return
        logging.error("Copying %s logs failed: %s", container,
                      result.stdout.decode(errors="replace"))
        raise RuntimeError(f"could not retain {container} logs")
    if evidence is not None and state["ExitCode"] == 127:
        shutil.copytree(directory.name,
                        self._rama_evidence_dir / evidence["case"] / container)
