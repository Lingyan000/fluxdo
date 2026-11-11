#!/usr/bin/env python3
"""用替身命令检查 CI 钥匙串配置，避免修改开发者本机钥匙串。"""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("setup_signing.sh")
MOCK_COMMAND = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

command = [Path(sys.argv[0]).name, *sys.argv[1:]]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(command) + '\\n')
if command[:2] == ['openssl', 'rand']:
    print('test-keychain-password')
if command[:2] == ['security', 'find-identity']:
    print('1) test-identity "FluxDO Code Signing"')
"""


class SigningSetupTest(unittest.TestCase):
    def check_setup(self, with_certificate):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            (root / "apple").mkdir()
            for name in ["security", "openssl", "sudo"]:
                executable = binaries / name
                executable.write_text(MOCK_COMMAND)
                executable.chmod(0o755)
            log = root / "commands.jsonl"
            env = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "RUNNER_TEMP": str(root),
                "COMMAND_LOG": str(log),
                "P12_BASE64": base64.b64encode(b"test certificate").decode() if with_certificate else "",
                "P12_PASSWORD": "test-password" if with_certificate else "",
            }
            subprocess.run(["bash", str(SCRIPT)], cwd=root, env=env, check=True, capture_output=True)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            keychain = str(root / "build.keychain-db")
            searches = [command for command in commands if command[:2] == ["security", "list-keychains"]]
            self.assertEqual(searches, [["security", "list-keychains", "-d", "user", "-s", keychain]])
            self.assertIn(["security", "default-keychain", "-s", keychain], commands)
            self.assertIn(["security", "unlock-keychain", "-p", "test-keychain-password", keychain], commands)
            self.assertEqual(any(command[:2] == ["security", "import"] for command in commands), with_certificate)
            self.assertEqual((root / "apple/Local.xcconfig").exists(), with_certificate)
            self.assertFalse((root / "codesign.p12").exists())

    def test_adhoc_build_isolates_keychain(self):
        self.check_setup(with_certificate=False)

    def test_certificate_build_isolates_keychain_and_imports_identity(self):
        self.check_setup(with_certificate=True)


if __name__ == "__main__":
    unittest.main()
