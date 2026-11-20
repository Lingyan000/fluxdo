"""验证 Release 复用、预发布转正式及失败重跑。"""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish_release


REPOSITORY = "example/fluxdo"
RELEASES = f"repos/{REPOSITORY}/releases"


class GitHubFixture:
    def __init__(self):
        self.releases = []
        self.requests = []
        self.upload_error = False
        self.upload_state = "uploaded"

    def add(self, tag, *, draft=False, immutable=False):
        release = {
            "id": len(self.releases) + 1,
            "tag_name": tag,
            "draft": draft,
            "immutable": immutable,
            "prerelease": "-" in tag,
            "assets": [],
        }
        self.releases.append(release)
        return release

    def api(self, endpoint, *, method="GET", payload=None):
        self.requests.append((endpoint, method, copy.deepcopy(payload)))
        if endpoint.startswith(f"repos/{REPOSITORY}/git/ref/tags/"):
            return {"object": {"sha": "built-commit"}}
        if method == "POST":
            release = self.add(payload["tag_name"])
            release.update(payload)
            return copy.deepcopy(release)
        if endpoint.startswith(f"{RELEASES}/assets/"):
            asset_id = int(endpoint.rsplit("/", 1)[1])
            for release in self.releases:
                release["assets"] = [
                    asset for asset in release["assets"] if asset["id"] != asset_id
                ]
            return None
        release_id = int(endpoint.rsplit("/", 1)[1])
        release = next(item for item in self.releases if item["id"] == release_id)
        if method == "DELETE":
            self.releases.remove(release)
            return None
        if method != "PATCH":
            raise AssertionError(f"意外的 API 请求 {method} {endpoint}")
        tag = payload.get("tag_name", release["tag_name"])
        if any(item["id"] != release_id and item["tag_name"] == tag for item in self.releases):
            raise AssertionError("目标标签已有 Release")
        release.update(payload)
        return copy.deepcopy(release)

    def list_all(self, endpoint):
        if endpoint == RELEASES:
            return copy.deepcopy(self.releases)
        release_id = int(endpoint.split("/")[-2])
        release = next(item for item in self.releases if item["id"] == release_id)
        return copy.deepcopy(release["assets"])

    def upload(self, arguments, **kwargs):
        tag = arguments[3]
        release = next(item for item in self.releases if item["tag_name"] == tag)
        if not release["draft"]:
            raise AssertionError("上传时 Release 必须是草稿")
        if self.upload_error:
            raise subprocess.CalledProcessError(1, arguments)
        if arguments[:3] != ["gh", "release", "upload"] or "--clobber" not in arguments:
            raise AssertionError("产物必须替换到现有 Release")
        for filename in arguments[arguments.index("--clobber") + 1:]:
            path = Path(filename)
            release["assets"] = [asset for asset in release["assets"] if asset["name"] != path.name]
            release["assets"].append({
                "id": 100 + len(release["assets"]),
                "name": path.name,
                "size": path.stat().st_size,
                "state": self.upload_state,
            })


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.assets = root / "dist"
        self.assets.mkdir()
        (self.assets / "fluxdo.apk").write_bytes(b"APK fixture")
        (self.assets / "fluxdo.apk.sha256").write_text("checksum fixture", encoding="utf-8")
        self.notes = root / "notes.md"
        self.notes.write_text("更新说明", encoding="utf-8")
        self.github = GitHubFixture()
        for target, replacement in (
            ("api", self.github.api),
            ("list_all", self.github.list_all),
            ("subprocess.run", self.github.upload),
        ):
            mock = patch(f"publish_release.{target}", replacement)
            mock.start()
            self.addCleanup(mock.stop)

    def publish(self, tag):
        return publish_release.publish_release(REPOSITORY, tag, self.assets, self.notes)

    def test_first_beta_has_prerelease_marker(self):
        self.assertTrue(self.publish("v0.2.31-beta.1"))
        release, = self.github.releases
        self.assertFalse(release["draft"])
        self.assertTrue(release["prerelease"])
        self.assertEqual(release["make_latest"], "false")
        self.assertEqual(release["tag_name"], "v0.2.31-beta.1")
        self.assertEqual(release["name"], "FluxDO v0.2.31-beta.1")
        self.assertEqual(release["body"], "更新说明")
        self.assertEqual(len(release["assets"]), 2)

    def test_beta_and_stable_reuse_id_and_replace_old_assets(self):
        release = self.github.add("v0.2.31-beta.9")
        release["assets"] = [{"id": 5, "name": "obsolete.apk", "size": 1, "state": "uploaded"}]
        self.assertTrue(self.publish("v0.2.31-beta.10"))
        self.assertEqual(len(self.github.releases), 1)
        self.assertEqual(release["tag_name"], "v0.2.31-beta.10")
        self.assertEqual(release["name"], "FluxDO v0.2.31-beta.10")
        self.assertTrue(release["prerelease"])
        self.assertEqual(release["make_latest"], "false")
        self.assertEqual(release["id"], 1)
        self.assertNotIn("obsolete.apk", [asset["name"] for asset in release["assets"]])
        self.assertTrue(self.publish("v0.2.31"))
        self.assertEqual(len(self.github.releases), 1)
        self.assertEqual(release["id"], 1)
        self.assertEqual(release["tag_name"], "v0.2.31")
        self.assertEqual(release["name"], "FluxDO v0.2.31")
        self.assertFalse(release["prerelease"])
        self.assertEqual(release["make_latest"], "legacy")

    def test_new_core_version_gets_its_own_release(self):
        previous = self.github.add("v0.2.30")
        before = copy.deepcopy(previous)
        self.publish("v0.2.31-beta.1")
        self.assertEqual(len(self.github.releases), 2)
        self.assertEqual(previous, before)

    def test_late_older_build_cannot_overwrite_newer_beta_or_stable(self):
        for current in ("v0.2.31-beta.10", "v0.2.31"):
            with self.subTest(current=current):
                self.github.releases.clear()
                self.github.requests.clear()
                self.github.add(current)
                self.assertFalse(self.publish("v0.2.31-beta.9"))
                self.assertTrue(all(method == "GET" for _, method, _ in self.github.requests))

    def test_retry_uses_same_release(self):
        self.publish("v0.2.31-beta.1")
        self.publish("v0.2.31-beta.1")
        self.assertEqual(len(self.github.releases), 1)
        self.assertEqual(len(self.github.releases[0]["assets"]), 2)

    def test_failed_upload_stays_draft_and_retry_recovers(self):
        release = self.github.add("v0.2.31-beta.9")
        self.github.upload_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish("v0.2.31-beta.10")
        self.assertTrue(release["draft"])
        self.assertEqual(release["tag_name"], "v0.2.31-beta.10")
        self.assertFalse(self.publish("v0.2.31-beta.9"))
        self.github.upload_error = False
        self.assertTrue(self.publish("v0.2.31-beta.10"))
        self.assertFalse(release["draft"])
        self.assertEqual(len(self.github.releases), 1)

    def test_incomplete_upload_does_not_publish(self):
        self.github.upload_state = "starter"
        with self.assertRaisesRegex(RuntimeError, "尚未完整上传"):
            self.publish("v0.2.31")
        self.assertTrue(self.github.releases[0]["draft"])

    def test_duplicate_releases_are_removed_after_target_is_published(self):
        self.github.add("v0.2.31-beta.1")
        target = self.github.add("v0.2.31-beta.2")
        layer = self.github.add("flatpak-wpe-layer-gnome48-v2")
        self.publish("v0.2.31-beta.2")
        self.assertEqual(self.github.releases, [target, layer])
        delete_index = next(i for i, (_, method, _) in enumerate(self.github.requests) if method == "DELETE")
        _, method, payload = self.github.requests[delete_index - 1]
        self.assertEqual(method, "PATCH")
        self.assertFalse(payload["draft"])

    def test_empty_artifacts_fail_before_mutations(self):
        for asset in self.assets.iterdir():
            asset.unlink()
        with self.assertRaisesRegex(ValueError, "没有产物"):
            self.publish("v0.2.31")
        self.assertEqual(self.github.requests, [])

    def test_immutable_release_is_reported_before_mutations(self):
        self.github.add("v0.2.31-beta.1", immutable=True)
        with self.assertRaisesRegex(RuntimeError, "已锁定"):
            self.publish("v0.2.31-beta.2")
        self.assertTrue(all(method == "GET" for _, method, _ in self.github.requests))


class VersionTest(unittest.TestCase):
    def test_semantic_precedence(self):
        tags = [
            "v0.2.30", "v0.2.31-1", "v0.2.31-alpha", "v0.2.31-beta",
            "v0.2.31-beta.2", "v0.2.31-beta.9", "v0.2.31-beta.10",
            "v0.2.31-beta.10.1", "v0.2.31-rc.1", "v0.2.31", "v0.2.32-beta.1",
        ]
        keys = [publish_release.Version.from_tag(tag).precedence for tag in tags]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(
            publish_release.Version.from_tag("v0.2.31-beta.10+123").precedence,
            publish_release.Version.from_tag("v0.2.31-beta.10+456").precedence,
        )

    def test_other_assets_and_invalid_versions_are_excluded(self):
        for tag in ("flatpak-wpe-layer-gnome48-v2", "v0.02.31", "v0.2.31-beta.01", "v0.2", "v0.2.31-"):
            with self.subTest(tag=tag):
                self.assertIsNone(publish_release.Version.from_tag(tag))


class GitHubTransportTest(unittest.TestCase):
    def test_pagination_flattens_all_pages(self):
        pages = [[{"id": 1}], [{"id": 2}]]
        with patch("publish_release.subprocess.run", return_value=subprocess.CompletedProcess([], 0, json.dumps(pages))) as run:
            self.assertEqual(publish_release.list_all(RELEASES), [{"id": 1}, {"id": 2}])
        self.assertIn("--paginate", run.call_args.args[0])
        self.assertIn("--slurp", run.call_args.args[0])

    def test_metadata_is_sent_as_json(self):
        payload = {"draft": True, "prerelease": False, "body": "更新说明\n第二行"}
        with patch("publish_release.subprocess.run", return_value=subprocess.CompletedProcess([], 0, '{"id": 3}')) as run:
            self.assertEqual(publish_release.api(RELEASES, method="POST", payload=payload), {"id": 3})
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), payload)


if __name__ == "__main__":
    unittest.main()
