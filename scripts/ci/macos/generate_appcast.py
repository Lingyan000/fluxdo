#!/usr/bin/env python3
"""Sign the existing DMG and publish an architecture-specific Sparkle feed."""

import argparse
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY_URL = "https://github.com/Lingyan000/fluxdo"


def sign_file(tool, path, private_key):
    result = subprocess.run(
        [str(tool), "--ed-key-file", "-", "-p", str(path)],
        input=private_key,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def generate_feed(app, dmg, architecture, tag, output, tool, private_key):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["CFBundleIdentifier"] != "com.github.lingyan000.fluxdo":
        raise ValueError("Unexpected application bundle identifier")
    version = info["CFBundleShortVersionString"]
    if tag != f"v{version}":
        raise ValueError("Release tag does not match the built application")
    if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("Missing or invalid Sparkle public key")
    if dmg.name != f"fluxdo-macos-{architecture}.dmg":
        raise ValueError("Unexpected DMG filename")

    signature = sign_file(tool, dmg, private_key)
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")
    subprocess.run([
        "/usr/bin/xcrun", "swift", str(Path(__file__).with_name("verify_update_signature.swift")),
        info["SUPublicEDKey"], signature, str(dmg),
    ], check=True)

    ET.register_namespace("sparkle", SPARKLE_NAMESPACE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = f"FluxDO macOS {architecture}"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"FluxDO {version}"
    ET.SubElement(item, "link").text = f"{REPOSITORY_URL}/releases/tag/{tag}"
    ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}version").text = str(info["CFBundleVersion"])
    ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}shortVersionString").text = version
    minimum = info["LSMinimumSystemVersion"].split(".")
    ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion").text = ".".join(
        minimum + ["0"] * (3 - len(minimum))
    )
    if architecture == "arm64":
        ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY_URL}/releases/download/{tag}/{dmg.name}",
        "length": str(dmg.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE_NAMESPACE}}}edSignature": signature,
    })
    output.mkdir(parents=True, exist_ok=True)
    feed = output / f"appcast-macos-{architecture}.xml"
    ET.indent(rss)
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    sign_file(tool, feed, private_key)
    print(f"Signed {dmg.name} and {feed.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    parser.add_argument(
        "--sign-tool", type=Path,
        default=Path("build/macos/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"),
    )
    args = parser.parse_args()
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    if not private_key:
        parser.error("SPARKLE_PRIVATE_KEY must be configured in GitHub Actions secrets")

    if not args.sign_tool.is_file():
        parser.error("Build the macOS app to resolve Sparkle, or pass --sign-tool")
    generate_feed(args.app, args.dmg, args.arch, args.tag, args.output, args.sign_tool, private_key)


if __name__ == "__main__":
    main()
