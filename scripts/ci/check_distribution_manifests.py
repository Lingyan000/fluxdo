#!/usr/bin/env python3
"""Exercise manifest generation with fixtures and validate official schemas."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.request import urlopen
import zipfile

import jsonschema
import yaml


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    generator = Path(__file__).with_name("generate_distribution_manifests.py")
    with tempfile.TemporaryDirectory() as directory:
        assets = Path(directory)
        hashes = {}
        for name in ["fluxdo-macos-arm64.dmg", "fluxdo-macos-x86_64.dmg", "fluxdo-windows-x86_64-setup.exe"]:
            data = f"Manifest validation fixture: {name}".encode()
            (assets / name).write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        subprocess.run([
            sys.executable, str(generator), "--version", "1.0.0", "--assets", str(assets),
        ], check=True)
        with zipfile.ZipFile(assets / "fluxdo-package-managers.zip") as archive:
            if len(archive.namelist()) != 4:
                raise ValueError("Expected one Cask and three WinGet manifests")
            archive.extractall(args.output)
        invalid = subprocess.run([
            sys.executable, str(generator), "--version", "1.0.0-beta.1", "--assets", str(assets),
        ], capture_output=True)
        if invalid.returncode == 0:
            raise ValueError("Prerelease version was accepted")

    cask = (args.output / "homebrew/Casks/fluxdo.rb").read_text()
    for architecture in ["arm64", "x86_64"]:
        if hashes[f"fluxdo-macos-{architecture}.dmg"] not in cask:
            raise ValueError("Cask archive checksum mismatch")
    for path in (args.output / "winget").rglob("*.yaml"):
        text = path.read_text()
        schema_url = text.splitlines()[0].split("$schema=", 1)[1]
        with urlopen(schema_url, timeout=30) as response:
            schema = json.load(response)
        manifest = yaml.safe_load(text)
        jsonschema.validate(manifest, schema)
        if manifest["PackageVersion"] != "1.0.0":
            raise ValueError("Unexpected package version")
        if manifest["ManifestType"] == "installer":
            installer = manifest["Installers"][0]
            if installer["InstallerSha256"] != hashes["fluxdo-windows-x86_64-setup.exe"].upper():
                raise ValueError("WinGet installer checksum mismatch")
        print(f"Validated {path.name}")
    print("Fixture manifests passed. These files are only for CI validation.")


if __name__ == "__main__":
    main()
