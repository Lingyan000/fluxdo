#!/usr/bin/env python3
"""QUIC client x server benchmark matrix over the interop-runner endpoint images.

Every implementation in the public QUIC interop runner ships an endpoint image with one
contract: `ROLE`, `TESTCASE`, `REQUESTS`, files under `/www`, downloads under `/downloads`,
certificates under `/certs`, HTTP/0.9 over ALPN `hq-interop` or HTTP/3 for `http3`.
Rama's image follows it too. So
the matrix costs no peer code: one image serves, another fetches, the fetch is timed.

The simulator is left out. The endpoint base image still routes everything through a `.2`
gateway on each side, so a plain forwarding container stands where the simulator would, and the
two subnets are the runner's own. Every pair crosses the same forwarder.

Standard library only.
"""

import argparse
import datetime as dt
import json
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = HERE / "bench.lock.json"
PREFIX = "quic-bench"
LEFT_NET, LEFT_SUBNET, LEFT_GATEWAY, CLIENT_IP = (
    f"{PREFIX}-left",
    "193.167.0.0/24",
    "193.167.0.2",
    "193.167.0.100",
)
RIGHT_NET, RIGHT_SUBNET, RIGHT_GATEWAY, SERVER_IP = (
    f"{PREFIX}-right",
    "193.167.100.0/24",
    "193.167.100.2",
    "193.167.100.100",
)
LEFT_SUBNET6, LEFT_GATEWAY6, CLIENT_IP6 = "fd00:cafe:cafe:0::/64", "fd00:cafe:cafe:0::2", "fd00:cafe:cafe:0::100"
RIGHT_SUBNET6, RIGHT_GATEWAY6, SERVER_IP6 = "fd00:cafe:cafe:100::/64", "fd00:cafe:cafe:100::2", "fd00:cafe:cafe:100::100"
SERVER_NAME = "server4"
UNITS = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30}
RAMA_IMAGE = "glendc/rama-quic-interop"
# A transfer run shorter than this many start-up baselines is marked as too short to trust.
SHORT_RUN_FACTOR = 4


class BenchError(Exception):
    pass


# The runner's certificate shape: a CA the clients trust and a leaf for the server names.
CERT_SCRIPT = """set -e
apk add --no-cache openssl >/dev/null
cd /certs
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -subj '/O=rama quic bench CA' -days 3 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout priv.key -out req.pem -subj '/CN=server' 2>/dev/null
printf 'subjectAltName=DNS:server,DNS:server4,DNS:server6,DNS:server46\n' > ext.cnf
openssl x509 -req -in req.pem -CA ca.pem -CAkey ca.key -CAcreateserial -out cert.pem -days 3 -extfile ext.cnf 2>/dev/null
chmod 644 ca.pem cert.pem priv.key
"""


# --- pure helpers -----------------------------------------------------------------------------


def parse_size(text):
    """`4G`, `8M`, `1K` or a plain byte count."""
    match = re.fullmatch(r"(\d+)([KMG]?)", str(text).strip().upper())
    if not match:
        raise BenchError(f"invalid size: {text!r}")
    return int(match.group(1)) * UNITS[match.group(2)]


def file_names(case, count):
    width = len(str(max(count - 1, 0)))
    return [f"{case}-{index:0{width}d}" for index in range(count)]


def requests_for(names):
    return " ".join(f"https://{SERVER_NAME}:443/{name}" for name in names)


def median(values):
    return statistics.median(values) if values else None


def cell_value(case, samples, handshake_seconds):
    """The number a cell reports, from its successful samples.

    Transfer cases subtract the pair's median handshake wall time, which is process start plus
    one connection, so the goodput is of the transfer and not of container start-up.
    """
    good = [s for s in samples if s.get("ok")]
    if not good:
        return None, None, None, False
    short = False
    if case["unit"] == "ms":
        values = [s["seconds"] * 1000 for s in good]
    else:
        base = handshake_seconds or 0.0
        values = []
        for s in good:
            active = max(s["seconds"] - base, 1e-3)
            # A run not clearly longer than the start-up it subtracts is dominated by noise.
            short |= s["seconds"] < SHORT_RUN_FACTOR * base
            if case["unit"] == "req/s":
                values.append(case["files"] / active)
            else:
                values.append(s["bytes"] / active / (1 << 20))
    return median(values), min(values), max(values), short


def format_value(value, unit):
    if value is None:
        return "n/a"
    if unit == "ms":
        return f"{value:.1f}"
    if value >= 100:
        return f"{value:.0f}"
    return f"{value:.1f}"


def table(case_name, unit, clients, servers, cells):
    """One text matrix: clients down, servers across."""
    width = max(len(s) for s in servers + ["server \\ client"]) + 2
    lines = [f"{case_name} [{unit}]  (rows: client, columns: server; median; * = run too short to trust)"]
    lines.append("".ljust(20) + "".join(s.rjust(width) for s in servers))
    for client in clients:
        row = client.ljust(20)
        for server in servers:
            cell = cells.get((client, server))
            if cell is None or cell.get("value") is None:
                row += "n/a".rjust(width)
            else:
                row += (format_value(cell["value"], unit) + ("*" if cell.get("short") else "")).rjust(width)
        lines.append(row)
    return "\n".join(lines)


def color_for(value, best, worst, higher_is_better):
    """A fixed blue scale: the best value darkest, the worst lightest."""
    if value is None or best == worst:
        ratio = 1.0
    else:
        ratio = (value - worst) / (best - worst)
        if not higher_is_better:
            ratio = 1.0 - (value - best) / (worst - best)
        ratio = min(max(ratio, 0.0), 1.0)
    light = 0xE8 - int(ratio * (0xE8 - 0x1F))
    light2 = 0xF0 - int(ratio * (0xF0 - 0x4E))
    return f"#{light:02x}{light2:02x}{0xF8:02x}" if ratio < 0.999 else "#1f4ef8"


def svg_escape(text):
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def heatmap_svg(case_name, case, clients, servers, cells, meta):
    """A self-contained heat-map: header block, client x server grid, footer."""
    higher_is_better = case["unit"] != "ms"
    values = [c["value"] for c in cells.values() if c.get("value") is not None]
    best = (max if higher_is_better else min)(values) if values else None
    worst = (min if higher_is_better else max)(values) if values else None
    longest = max(len(n) for n in clients + servers)
    cell_w, cell_h, top = max(120, longest * 8 + 24), 54, 150
    left = longest * 8 + 32
    width = max(left + cell_w * len(servers) + 24, 1100)
    height = top + cell_h * len(clients) + 130
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="13">',
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        '<defs><pattern id="na" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
        '<line x1="0" y1="0" x2="0" y2="8" stroke="#c8c8c8" stroke-width="2"/></pattern></defs>',
        f'<text x="16" y="30" font-size="20" font-weight="bold">QUIC {svg_escape(meta.get("protocol", "hq-interop"))} {svg_escape(case_name)}: '
        f'{svg_escape(case["description"])} [{svg_escape(case["unit"])}]</text>',
    ]
    header = [
        f"{meta['os']} · {meta['arch']} · {meta['cpus']} cpus · docker {meta['docker']}",
        f"{meta['timestamp']} · rama {meta['rama_commit']} · workload {case['files']} × {case['size']}"
        f" · {meta['repeat']} runs, median shown",
    ]
    for index, line in enumerate(header):
        out.append(f'<text x="16" y="{56 + 18 * index}" fill="#333">{svg_escape(line)}</text>')
    out.append(f'<text x="16" y="{top - 40}" fill="#555">rows: client · columns: server</text>')
    for column, server in enumerate(servers):
        x = left + column * cell_w + cell_w / 2
        out.append(f'<text x="{x:.0f}" y="{top - 10}" text-anchor="middle">{svg_escape(server)}</text>')
    for row, client in enumerate(clients):
        y = top + row * cell_h
        out.append(f'<text x="{left - 8}" y="{y + cell_h / 2 + 5:.0f}" text-anchor="end">{svg_escape(client)}</text>')
        for column, server in enumerate(servers):
            x = left + column * cell_w
            cell = cells.get((client, server)) or {}
            value = cell.get("value")
            if value is None:
                out.append(f'<rect x="{x}" y="{y}" width="{cell_w}" height="{cell_h}" fill="url(#na)" stroke="#fff"/>')
                out.append(
                    f'<text x="{x + cell_w / 2:.0f}" y="{y + cell_h / 2 + 5:.0f}" text-anchor="middle" fill="#666">n/a</text>'
                )
                continue
            fill = color_for(value, best, worst, higher_is_better)
            dark = value == best
            out.append(f'<rect x="{x}" y="{y}" width="{cell_w}" height="{cell_h}" fill="{fill}" stroke="#fff"/>')
            colour = "#fff" if dark else "#111"
            marker = "*" if cell.get("short") else ""
            out.append(
                f'<text x="{x + cell_w / 2:.0f}" y="{y + cell_h / 2 - 2:.0f}" text-anchor="middle" '
                f'font-weight="bold" fill="{colour}">{format_value(value, case["unit"])}{marker}</text>'
            )
            out.append(
                f'<text x="{x + cell_w / 2:.0f}" y="{y + cell_h / 2 + 16:.0f}" text-anchor="middle" '
                f'font-size="10" fill="{colour}">{format_value(cell["min"], case["unit"])} – '
                f'{format_value(cell["max"], case["unit"])}</text>'
            )
    footer_y = top + cell_h * len(clients) + 30
    footer = [
        f"loopback bridge on one host through one forwarding container; {'higher' if higher_is_better else 'lower'} is better",
        "compares pairs on this host only",
    ]
    if any(c.get("short") for c in cells.values()):
        footer.append("* run shorter than four start-up baselines: raise the workload before trusting it")
    if meta.get("emulated"):
        footer.append(f"emulated, not native {meta['arch']}: {', '.join(meta['emulated'])}")
    if meta.get("virtualized"):
        footer.append("Docker runs in a virtual machine on this host; absolute numbers reflect its network path")
    for index, line in enumerate(footer):
        out.append(f'<text x="16" y="{footer_y + 18 * index}" fill="#555" font-size="12">{svg_escape(line)}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


# --- docker plumbing ----------------------------------------------------------------------------


def run(command, *, check=True, capture=True, timeout=None):
    result = subprocess.run(command, text=True, capture_output=capture, timeout=timeout)
    if check and result.returncode != 0:
        raise BenchError(f"{' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}")
    return result


def docker(*args, **kwargs):
    return run(["docker", *args], **kwargs)


def quiet(*args):
    return docker(*args, check=False)


def apply_overrides(lock, overrides):
    """`--set bulk.size=64M`: a smaller or larger workload than the lockfile's."""
    for item in overrides or []:
        match = re.fullmatch(r"(\w+)\.(files|size)=(\S+)", item)
        if not match or match.group(1) not in lock["cases"]:
            raise BenchError(f"invalid --set {item!r}; use <case>.files=<n> or <case>.size=<bytes>")
        case, key, value = match.groups()
        lock["cases"][case][key] = int(value) if key == "files" else value
    return lock


def load_lock(overrides=None, protocol="hq-interop"):
    lock = apply_overrides(json.loads(LOCK.read_text()), overrides)
    if protocol == "h3":
        # Share reviewed peer pins with interoperability; never substitute a
        # moving peer tag when comparing H3 runs.
        runner = json.loads((HERE.parent / "interop-runner/runner.lock.json").read_text())
        lock["implementations"] = {
            name: spec for name, spec in lock["implementations"].items()
            if "rama_backend" in spec or name in runner["peers"]
        }
        for name, image in runner["peers"].items():
            lock["implementations"][name]["image"] = image
        for case in lock["cases"].values():
            case["testcase"] = "http3"
            case["alpn"] = "h3"
    for name, case in lock["cases"].items():
        case["description"] = {
            "bulk": "one stream, one large file",
            "parallel": "many streams at once",
            "small": "many small streams at once",
            "handshake": "process start plus one connection, 1-byte fetch",
        }.get(name, name)
    return lock


def image_for(name, spec, args):
    if "rama_backend" in spec:
        return f"{RAMA_IMAGE}:{spec['rama_backend']}-{args.rama_tag}"
    return spec["image"]


def ensure_rama_image(spec, args):
    """Build the Rama endpoint image for this backend unless it is already there."""
    image = image_for("", spec, args)
    if args.build_rama or docker("image", "inspect", image, check=False).returncode != 0:
        build_rama(spec, args)
    return image


def build_rama(spec, args):
    image = image_for("", spec, args)
    print(f"building {image}", flush=True)
    docker(
        "build",
        "--platform",
        args.platform,
        "--build-arg",
        f"TLS_BACKEND={spec['rama_backend']}",
        "--tag",
        image,
        "--file",
        str(ROOT / "rama-quic/e2e/interop-runner/Dockerfile"),
        str(ROOT),
        capture=False,
    )


def ensure_image(image, args):
    if docker("image", "inspect", image, check=False).returncode != 0:
        print(f"pulling {image}", flush=True)
        docker("pull", "--platform", args.platform, image, capture=False)
    info = json.loads(docker("image", "inspect", image).stdout)[0]
    digest = (info.get("RepoDigests") or [info["Id"]])[0]
    return info["Architecture"], digest


def docker_arch(name):
    """Docker's image architecture names, for the daemon's and the images' to compare."""
    return {"aarch64": "arm64", "x86_64": "amd64"}.get(name, name)


def host_meta(args, repeat):
    info = json.loads(docker("info", "--format", "{{json .}}").stdout)
    commit = run(["git", "-C", str(ROOT), "rev-parse", "--short=9", "HEAD"]).stdout.strip()
    dirty = run(["git", "-C", str(ROOT), "status", "--short"]).stdout.strip() != ""
    return {
        "os": f"{platform.system()} {platform.release()}",
        "docker_os": f"{info.get('OperatingSystem', '?')} / kernel {info.get('KernelVersion', '?')}",
        "arch": docker_arch(info.get("Architecture", platform.machine())),
        "cpus": info.get("NCPU"),
        "memory_bytes": info.get("MemTotal"),
        "docker": info.get("ServerVersion"),
        "virtualized": platform.system() != "Linux",
        "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "rama_commit": commit + ("-dirty" if dirty else ""),
        "platform": args.platform,
        "repeat": repeat,
    }


def prepare_content(lock, args, workdir):
    """Certificates and served files, both made inside containers so the host needs only Docker."""
    certs = workdir / "certs"
    certs.mkdir()
    print("generating certificates", flush=True)
    docker("run", "--rm", "-v", f"{certs}:/certs", "alpine:3", "sh", "-c", CERT_SCRIPT, capture=False)
    volume = f"{PREFIX}-www"
    quiet("volume", "rm", "-f", volume)
    docker("volume", "create", volume)
    script = ["set -e", "cd /www"]
    expected = {}
    for name, case in lock["cases"].items():
        if name not in args.cases:
            continue
        size = parse_size(case["size"])
        names = file_names(name, case["files"])
        expected[name] = {"names": names, "bytes": size * len(names)}
        if case["files"] == 1:
            script.append(f"head -c {size} /dev/urandom > {names[0]}")
        else:
            script.append(f"head -c {size} /dev/urandom > .seed-{name}")
            script.append(f"for f in {' '.join(names)}; do ln .seed-{name} $f; done")
    print("generating served files", flush=True)
    docker("run", "--rm", "-v", f"{volume}:/www", "alpine:3", "sh", "-c", "\n".join(script), capture=False)
    for files in expected.values():
        hashes = docker("run", "--rm", "-v", f"{volume}:/www:ro", "alpine:3", "sh", "-c",
                        "cd /www && sha256sum " + " ".join(files["names"])).stdout
        files["hashes"] = parse_hashes(hashes)
    return certs, volume, expected


def parse_hashes(output):
    result = {}
    for line in output.splitlines():
        digest, name = line.split(maxsplit=1)
        name = name.lstrip("*")
        if not re.fullmatch(r"[0-9a-f]{64}", digest) or name in result:
            raise BenchError("invalid or duplicate content hash")
        result[name] = digest
    return result


def occupied_subnets():
    """Other networks already on the runner's subnets, which Docker would refuse to overlap."""
    taken = []
    for net in docker("network", "ls", "--format", "{{.Name}}").stdout.split():
        if net in (LEFT_NET, RIGHT_NET):
            continue
        inspected = json.loads(docker("network", "inspect", net).stdout)[0]
        for config in (inspected.get("IPAM") or {}).get("Config") or []:
            if str(config.get("Subnet", "")).startswith(("193.167.", "fd00:cafe:cafe:")):
                taken.append(f"{net} ({config['Subnet']})")
    return taken


def start_network(args):
    for name in (f"{PREFIX}-sim", f"{PREFIX}-server"):
        quiet("rm", "-f", name)
    for net in (LEFT_NET, RIGHT_NET):
        quiet("network", "rm", net)
    taken = occupied_subnets()
    if taken:
        raise BenchError(f"the runner subnets are in use by other Docker networks: {', '.join(taken)}")
    # Docker's default gateway mode drops packets addressed to the opposite bridge
    # before they reach our router. Allow this routing only on the benchmark networks.
    network_options = ["--ipv6", "-o", "com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected",
                       "-o", "com.docker.network.bridge.gateway_mode_ipv6=nat-unprotected"]
    docker("network", "create", *network_options, "--subnet", LEFT_SUBNET, "--subnet", LEFT_SUBNET6, LEFT_NET)
    docker("network", "create", *network_options, "--subnet", RIGHT_SUBNET, "--subnet", RIGHT_SUBNET6, RIGHT_NET)
    # The forwarder: the endpoints' default gateway on both sides, and the `sim` the clients wait for.
    docker("run", "-d", "--name", f"{PREFIX}-sim", "--cap-add", "NET_ADMIN",
           "--sysctl", "net.ipv4.ip_forward=1", "--sysctl", "net.ipv6.conf.all.forwarding=1",
           "--network", LEFT_NET, "--ip", LEFT_GATEWAY, "--ip6", LEFT_GATEWAY6,
           "alpine:3", "sh", "-c", "while true; do nc -l -p 57832 </dev/null >/dev/null; done")
    docker("network", "connect", "--ip", RIGHT_GATEWAY, "--ip6", RIGHT_GATEWAY6, RIGHT_NET, f"{PREFIX}-sim")


def stop_network():
    for name in (f"{PREFIX}-sim", f"{PREFIX}-server", f"{PREFIX}-client"):
        quiet("rm", "-f", name)
    for net in (LEFT_NET, RIGHT_NET):
        quiet("network", "rm", net)


def role_options(spec, role):
    """Per-implementation `env` and `<role>_entrypoint` from the lockfile, as docker arguments."""
    options = []
    for key, value in (spec.get("env") or {}).items():
        options += ["-e", f"{key}={value}"]
    entrypoint = spec.get(f"{role}_entrypoint")
    if entrypoint:
        options += ["--entrypoint", entrypoint[0]]
    return options, (entrypoint[1:] if entrypoint else [])


def start_server(spec, certs, volume, testcase, args, label="server"):
    save_logs(args, label)
    quiet("rm", "-f", f"{PREFIX}-server")
    options, trailing = role_options(spec, "server")
    docker("run", "-d", "--name", f"{PREFIX}-server", "--cap-add", "NET_ADMIN",
           "--network", RIGHT_NET, "--ip", SERVER_IP, "--ip6", SERVER_IP6,
           "-e", "ROLE=server", "-e", f"TESTCASE={testcase}", *options,
           "-v", f"{volume}:/www:ro", "-v", f"{certs}:/certs:ro", spec["image"], *trailing)
    time.sleep(args.settle)


def parse_docker_time(text):
    """`2026-09-15T16:03:38.123456789Z` to seconds since the epoch."""
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?Z", text.strip())
    if not match:
        raise BenchError(f"unexpected docker timestamp: {text!r}")
    base = dt.datetime.fromisoformat(match.group(1)).replace(tzinfo=dt.timezone.utc).timestamp()
    fraction = (match.group(2) or "0")[:9].ljust(9, "0")
    return base + int(fraction) / 1e9


def save_logs(args, label):
    """Keep a container's output under `--logs` so endpoint counters can be read after a run."""
    if not args.logs or label.endswith(".none"):
        return
    args.logs.mkdir(parents=True, exist_ok=True)
    logs = docker("logs", f"{PREFIX}-{label.split('.')[0]}", check=False)
    (args.logs / f"{label}.log").write_text((logs.stdout or "") + (logs.stderr or ""))


def run_client(spec, certs, testcase, names, args, expected, label="client"):
    """One client run: its process lifetime from the container's own timestamps, the bytes it
    downloaded, and whether they were the right ones."""
    downloads = f"{PREFIX}-downloads"
    name = f"{PREFIX}-client"
    quiet("rm", "-f", name)
    quiet("volume", "rm", "-f", downloads)
    docker("volume", "create", downloads)
    options, trailing = role_options(spec, "client")
    command = ["run", "-d", "--name", name, "--cap-add", "NET_ADMIN",
               "--network", LEFT_NET, "--ip", CLIENT_IP, "--ip6", CLIENT_IP6,
               "--add-host", f"{SERVER_NAME}:{SERVER_IP}", "--add-host", f"sim:{LEFT_GATEWAY}",
               "-e", "ROLE=client", "-e", f"TESTCASE={testcase}", "-e", f"REQUESTS={requests_for(names)}",
               *options, "-v", f"{certs}:/certs:ro", "-v", f"{downloads}:/downloads", spec["image"], *trailing]
    docker(*command)
    try:
        waited = docker("wait", name, check=False, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        waited = None
    if waited is None or waited.returncode != 0:
        quiet("kill", name)
        sample = {"seconds": float(args.timeout), "exit": None, "bytes": 0, "ok": False, "error": "timeout"}
        save_logs(args, label)
        quiet("rm", "-f", name)
        return sample
    state = json.loads(docker("inspect", name).stdout)[0]["State"]
    seconds = parse_docker_time(state["FinishedAt"]) - parse_docker_time(state["StartedAt"])
    code = int(waited.stdout.strip() or state.get("ExitCode", 1))
    sample = {"seconds": round(seconds, 4), "exit": code, "bytes": 0, "ok": False}
    if code == 127:
        sample["error"] = "unsupported"
    elif code != 0:
        logs = docker("logs", "--tail", "5", name, check=False)
        sample["error"] = (logs.stderr or logs.stdout).strip()[-400:] or f"exit {code}"
    save_logs(args, label)
    quiet("rm", "-f", name)
    if "error" in sample:
        return sample
    sizes = docker("run", "--rm", "-v", f"{downloads}:/downloads:ro", "alpine:3", "sh", "-c",
                   "cd /downloads && for f in *; do if [ -f \"$f\" ]; then stat -c '%s' \"$f\" || exit; fi; done").stdout.split()
    total = sum(int(s) for s in sizes)
    sample["bytes"] = total
    if len(sizes) != len(names) or total != expected["bytes"]:
        sample["error"] = f"downloaded {len(sizes)} files, {total} bytes; expected {len(names)} files, {expected['bytes']} bytes"
        return sample
    hashes = docker("run", "--rm", "-v", f"{downloads}:/downloads:ro", "alpine:3", "sh", "-c",
                    "cd /downloads && sha256sum *").stdout
    if parse_hashes(hashes) != expected["hashes"]:
        sample["error"] = "download contents differ from the served files"
        return sample
    sample["content_verified"] = True
    sample["ok"] = True
    return sample


def run_matrix(args):
    lock = load_lock(args.set, args.protocol)
    names = args.implementations or list(lock["implementations"])
    unknown = [n for n in names if n not in lock["implementations"]]
    if unknown:
        raise BenchError(f"unknown implementations: {unknown}")
    cases = {n: lock["cases"][n] for n in args.cases}
    meta = host_meta(args, args.repeat)
    meta["protocol"] = args.protocol
    meta["alpn_validation"] = "endpoint http3 contract" if args.protocol == "h3" else "endpoint hq-interop contract"
    images, emulated = {}, []
    for name in names:
        spec = lock["implementations"][name]
        if "rama_backend" in spec:
            ensure_rama_image(spec, args)
        image = image_for(name, spec, args)
        arch, digest = ensure_image(image, args)
        images[name] = {"image": image, "digest": digest, "arch": arch, **{
            k: v for k, v in spec.items() if k in ("env", "client_entrypoint", "server_entrypoint", "note")}}
        if arch != meta["arch"]:
            emulated.append(f"{name} ({arch})")
    meta["emulated"] = emulated
    meta["images"] = images
    order = (["handshake"] if "handshake" in cases else []) + [c for c in cases if c != "handshake"]
    report = {"meta": meta, "cases": cases, "implementations": names, "cells": []}
    workdir = Path(tempfile.mkdtemp(prefix=f"{PREFIX}-"))
    previous = "none"
    try:
        certs, volume, expected = prepare_content(lock, args, workdir)
        start_network(args)
        previous = "none"
        for server in names:
            for client in names:
                handshake_seconds = None
                for case_name in order:
                    case = cases[case_name]
                    start_server(images[server], certs, volume, case["testcase"], args,
                                 label=f"server.{previous}")
                    previous = f"{case_name}.{client}.{server}"
                    files = expected[case_name]
                    samples = []
                    runs = args.repeat + 1  # the first is a warm-up
                    if case_name == "handshake":
                        runs = args.handshake_runs + 1
                    for index in range(runs):
                        sample = run_client(images[client], certs, case["testcase"], files["names"],
                                            args, files, label=f"client.{previous}.{index}")
                        if index > 0:
                            samples.append(sample)
                        if sample.get("error") == "unsupported" or (index == 0 and not sample["ok"]):
                            samples = [sample]
                            break
                    if case_name == "handshake":
                        good = [s["seconds"] for s in samples if s["ok"]]
                        handshake_seconds = median(good)
                    value, low, high, short = cell_value(case, samples, handshake_seconds)
                    cell = {"case": case_name, "client": client, "server": server, "samples": samples,
                            "value": value, "min": low, "max": high, "short": short,
                            "baseline_seconds": handshake_seconds}
                    report["cells"].append(cell)
                    args.out.mkdir(parents=True, exist_ok=True)
                    (args.out / "in-progress.json").write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
                    shown = format_value(value, case["unit"]) + ("*" if short else "")
                    problem = next((s.get("error") for s in samples if s.get("error")), "")
                    print(f"{case_name:10} client={client:20} server={server:20} {shown:>8} {case['unit']}"
                          f"  {problem[:80]}", flush=True)
    finally:
        save_logs(args, f"server.{previous}")
        stop_network()
        quiet("volume", "rm", "-f", f"{PREFIX}-www", f"{PREFIX}-downloads")
        shutil.rmtree(workdir, ignore_errors=True)
    return report


def render(report, svg_dir):
    names = report["implementations"]
    for case_name, case in report["cases"].items():
        cells = {(c["client"], c["server"]): c for c in report["cells"] if c["case"] == case_name}
        print()
        print(table(case_name, case["unit"], names, names, cells))
        if svg_dir:
            svg_dir.mkdir(parents=True, exist_ok=True)
            (svg_dir / f"{case_name}.svg").write_text(heatmap_svg(case_name, case, names, names, cells, report["meta"]))
    if svg_dir:
        print(f"\nSVGs written to {svg_dir}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--protocol", choices=["hq-interop", "h3"], default="hq-interop",
                        help="wire protocol; H3 uses the independent runner's pinned peers")
    parser.add_argument("--implementations", type=lambda s: s.split(","), help="comma-separated subset of bench.lock.json")
    parser.add_argument("--cases", type=lambda s: s.split(","), default=["handshake", "bulk", "parallel", "small"])
    parser.add_argument("--set", action="append", metavar="CASE.KEY=VALUE",
                        help="override a case's files or size, e.g. bulk.size=256M")
    parser.add_argument("--repeat", type=int, default=3, help="measured runs per transfer cell, after one warm-up")
    parser.add_argument("--handshake-runs", type=int, default=10, help="measured runs per handshake cell")
    parser.add_argument("--settle", type=float, default=2.0, help="seconds to let a server start")
    parser.add_argument("--timeout", type=int, default=900, help="seconds per client run")
    parser.add_argument("--platform", default=None, help="docker platform; defaults to the daemon's")
    parser.add_argument("--rama-tag", default=None, help="tag suffix of the local Rama images; defaults to the platform's architecture")
    parser.add_argument("--build-rama", action="store_true", help="rebuild the Rama images even when present")
    parser.add_argument("--logs", type=Path, default=None,
                        help="keep every client and server container log in this directory")
    parser.add_argument("--out", type=Path, default=ROOT / "target/quic-bench", help="directory for the JSON report")
    parser.add_argument("--svg", default=str(HERE / "graph"),
                        help="directory for the SVG heat-maps; pass 'none' to write no charts")
    parser.add_argument("--report", type=Path, help="render this saved JSON report instead of running")
    args = parser.parse_args()
    if args.protocol == "h3" and not args.report:
        args.out = args.out / "h3"
        if args.svg not in ("", "none"):
            args.svg = str(Path(args.svg) / "h3")
    if args.platform is None:
        info = json.loads(docker("info", "--format", "{{json .}}").stdout)
        args.platform = f"linux/{docker_arch(info.get('Architecture'))}"
    if args.rama_tag is None:
        args.rama_tag = args.platform.split("/")[-1]
    svg_dir = None if args.svg in ("", "none") else Path(args.svg)
    if args.report:
        report = json.loads(args.report.read_text())
    else:
        if args.logs is None:
            args.logs = args.out / "logs" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        report = run_matrix(args)
        args.out.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        path = args.out / f"{stamp}.json"
        path.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
        print(f"\nreport written to {path}")
    render(report, svg_dir)


if __name__ == "__main__":
    try:
        main()
    except BenchError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
