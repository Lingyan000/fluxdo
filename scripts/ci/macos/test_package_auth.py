#!/usr/bin/env python3
"""检查 Flutter 使用的 Xcode 包装入口，避免认证参数遗漏或原始参数被拆分。"""

from pathlib import Path
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).with_name("xcrun")


class PackageAuthTest(unittest.TestCase):
    def run_wrapper(self, arguments):
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "xcrun"
            # 用 printf 替换系统工具，测试不会调用开发者本机的 Xcode。
            wrapper.write_text(
                "capture() { printf '%s\\n' \"$@\"; exit 0; }\n"
                + WRAPPER.read_text(encoding="utf-8").replace("exec /usr/bin/xcrun", "capture"),
                encoding="utf-8", newline="\n",
            )
            result = subprocess.run(
                ["bash", str(wrapper), *arguments],
                check=True, capture_output=True, text=True,
            )
            return result.stdout.splitlines()

    def test_project_commands_use_netrc(self):
        for command in ["-list", "-showBuildSettings", "-resolvePackageDependencies", "build"]:
            with self.subTest(command=command):
                arguments = ["xcodebuild", command, "-project", "path with spaces/Runner.xcodeproj"]
                self.assertEqual(self.run_wrapper(arguments), [
                    "xcodebuild", "-packageAuthorizationProvider", "netrc", *arguments[1:]
                ])

    def test_other_tools_and_version_keep_arguments(self):
        for arguments in [["clang", "--version"], ["--find", "xcodebuild"], ["xcodebuild", "-version"]]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_wrapper(arguments), arguments)


if __name__ == "__main__":
    unittest.main()
