#!/usr/bin/env python3
"""Generate Homebrew Cask and WinGet manifests from the release artifacts."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


REPOSITORY = "https://github.com/Lingyan000/fluxdo"
PACKAGE_ID = "Lingyan000.FluxDO"
SCHEMA_VERSION = "1.28.0"


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifests(version, hashes):
    cask = f'''cask "fluxdo" do
  arch arm: "arm64", intel: "x86_64"

  version "{version}"
  sha256 arm:   "{hashes['fluxdo-macos-arm64.dmg']}",
         intel: "{hashes['fluxdo-macos-x86_64.dmg']}"

  url "{REPOSITORY}/releases/download/v#{{version}}/fluxdo-macos-#{{arch}}.dmg"
  name "FluxDO"
  desc "Unofficial Linux.do community client"
  homepage "{REPOSITORY}"

  auto_updates true
  depends_on macos: :monterey

  app "fluxdo.app"
end
'''
    root = f"winget/manifests/l/Lingyan000/FluxDO/{version}/{PACKAGE_ID}"
    common = f"PackageIdentifier: {PACKAGE_ID}\nPackageVersion: {json.dumps(version)}\n"
    installer = common + f'''InstallerType: inno
Scope: user
UpgradeBehavior: install
ProductCode: '{{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}}_is1'
Installers:
- Architecture: x64
  InstallerUrl: {REPOSITORY}/releases/download/v{version}/fluxdo-windows-x86_64-setup.exe
  InstallerSha256: {hashes['fluxdo-windows-x86_64-setup.exe'].upper()}
ManifestType: installer
ManifestVersion: {SCHEMA_VERSION}
'''
    locale = common + f'''PackageLocale: en-US
Publisher: FluxDO
PublisherUrl: {REPOSITORY}
PublisherSupportUrl: {REPOSITORY}/issues
PackageName: FluxDO
PackageUrl: {REPOSITORY}
License: GPL-3.0
LicenseUrl: {REPOSITORY}/blob/main/LICENSE
ShortDescription: Unofficial Linux.do community client
Moniker: fluxdo
ReleaseNotesUrl: {REPOSITORY}/releases/tag/v{version}
ManifestType: defaultLocale
ManifestVersion: {SCHEMA_VERSION}
'''
    files = {
        "homebrew/Casks/fluxdo.rb": cask,
        f"{root}.yaml": common + f"DefaultLocale: en-US\nManifestType: version\nManifestVersion: {SCHEMA_VERSION}\n",
        f"{root}.installer.yaml": installer,
        f"{root}.locale.en-US.yaml": locale,
    }
    for name, content in files.items():
        if name.endswith(".yaml"):
            manifest_type = re.search(r"^ManifestType: (.+)$", content, re.MULTILINE)[1]
            schema = f"https://aka.ms/winget-manifest.{manifest_type}.{SCHEMA_VERSION}.schema.json"
            files[name] = f"# yaml-language-server: $schema={schema}\n\n{content}"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--assets", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("Only stable release versions can be distributed")
    hashes = {
        name: checksum(args.assets / name)
        for name in ["fluxdo-macos-arm64.dmg", "fluxdo-macos-x86_64.dmg", "fluxdo-windows-x86_64-setup.exe"]
    }
    output = args.assets / "fluxdo-package-managers.zip"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in manifests(args.version, hashes).items():
            archive.writestr(name, content)
    print(f"Generated {output}")


if __name__ == "__main__":
    main()
