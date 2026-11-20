#!/usr/bin/env python3
"""同一核心版本复用一个 GitHub Release，上传完整产物后公开。"""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess


TAG_PATTERN = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


@dataclass(frozen=True)
class Version:
    core: tuple[int, int, int]
    prerelease: tuple[str, ...]

    @property
    def precedence(self):
        identifiers = tuple(
            (0, int(part)) if part.isdigit() else (1, part)
            for part in self.prerelease
        )
        return (*self.core, not self.prerelease, identifiers)

    @classmethod
    def from_tag(cls, tag):
        match = TAG_PATTERN.fullmatch(tag)
        if match is None:
            return None
        prerelease = tuple(match[4].split(".")) if match[4] else ()
        if any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in prerelease):
            return None
        return cls(tuple(int(match[index]) for index in (1, 2, 3)), prerelease)


def api(endpoint, *, method="GET", payload=None):
    arguments = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        arguments.extend(["--input", "-"])
    result = subprocess.run(
        arguments,
        input=json.dumps(payload) if payload is not None else None,
        text=True,
        stdout=subprocess.PIPE,
        check=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def list_all(endpoint):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"{endpoint}?per_page=100"],
        text=True,
        stdout=subprocess.PIPE,
        check=True,
    )
    return [item for page in json.loads(result.stdout) for item in page]


def publish_release(repository, tag, assets_directory, notes_path):
    version = Version.from_tag(tag)
    if version is None:
        raise ValueError(f"无法识别应用版本标签 {tag}")
    assets = sorted(path for path in assets_directory.iterdir() if path.is_file())
    if not assets:
        raise ValueError("发布目录中没有产物")
    notes = notes_path.read_text(encoding="utf-8")
    endpoint = f"repos/{repository}/releases"

    # 标签必须来自已构建的提交，避免 Release API 自动创建标签。
    api(f"repos/{repository}/git/ref/tags/{tag}")
    releases = list_all(endpoint)
    matching = []
    for release in releases:
        existing = Version.from_tag(release["tag_name"])
        if existing is not None and existing.core == version.core:
            matching.append((existing, release))

    current = None
    if matching:
        newest, current = max(matching, key=lambda item: item[0].precedence)
        if newest.precedence > version.precedence:
            print(f"跳过 {tag}，已存在更高版本 {current['tag_name']}")
            return False
        # 兼容此前按完整标签分别创建的 Release，优先接续目标标签。
        current = next(
            (release for _, release in matching if release["tag_name"] == tag),
            current,
        )
        if current.get("immutable"):
            raise RuntimeError(f"Release {current['tag_name']} 已锁定，无法替换产物")

    metadata = {
        "tag_name": tag,
        "name": f"FluxDO {tag}",
        "body": notes,
        "draft": True,
        "prerelease": bool(version.prerelease),
        "make_latest": "false",
    }
    if current is None:
        current = api(endpoint, method="POST", payload=metadata)
    else:
        current = api(f"{endpoint}/{current['id']}", method="PATCH", payload=metadata)
    release_endpoint = f"{endpoint}/{current['id']}"

    # 复用 Release ID。产物替换期间保持草稿，失败后可用同一标签重跑。
    expected = {path.name: path.stat().st_size for path in assets}
    for asset in list_all(f"{release_endpoint}/assets"):
        if asset["name"] not in expected:
            api(f"{endpoint}/assets/{asset['id']}", method="DELETE")
    subprocess.run(
        ["gh", "release", "upload", tag, "--repo", repository, "--clobber", *map(str, assets)],
        check=True,
    )
    uploaded = list_all(f"{release_endpoint}/assets")
    if (
        {asset["name"]: asset["size"] for asset in uploaded} != expected
        or any(asset["state"] != "uploaded" for asset in uploaded)
    ):
        raise RuntimeError("Release 产物尚未完整上传，保留草稿供重跑")

    api(
        release_endpoint,
        method="PATCH",
        payload={
            "draft": False,
            "prerelease": bool(version.prerelease),
            "make_latest": "false" if version.prerelease else "legacy",
        },
    )
    # 先完成新产物发布，再收拢同核心版本遗留的重复 Release。
    for _, release in matching:
        if release["id"] != current["id"]:
            api(f"{endpoint}/{release['id']}", method="DELETE")
    print(f"已发布 {tag}，Release ID 为 {current['id']}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--print-core", action="store_true")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--assets", type=Path, default=Path("dist"))
    parser.add_argument("--notes", type=Path, default=Path("release_notes.md"))
    args = parser.parse_args()
    version = Version.from_tag(args.tag)
    if version is None:
        parser.error(f"无法识别应用版本标签 {args.tag}")
    if args.print_core:
        print(".".join(map(str, version.core)))
        return
    if not args.repo:
        parser.error("需要 --repo 或 GITHUB_REPOSITORY")
    published = publish_release(args.repo, args.tag, args.assets, args.notes)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as destination:
            destination.write(f"published={str(published).lower()}\n")


if __name__ == "__main__":
    main()
