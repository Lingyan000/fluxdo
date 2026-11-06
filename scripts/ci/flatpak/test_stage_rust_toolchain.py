"""验证离线工具链搬迁和旧编译器提前拒绝，不依赖本机安装 Linux SDK。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('stage_rust_toolchain.sh').resolve()


class StageRustToolchainTest(unittest.TestCase):
    def test_stages_actual_compiler_and_rejects_old_or_wrong_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            (source / 'core/net_core').mkdir(parents=True)
            (source / 'core/net_core/Cargo.toml').write_text('rust-version = "1.96"\n')
            sdk = root / 'toolchain'
            (sdk / 'bin').mkdir(parents=True)
            (sdk / 'lib').mkdir()
            (sdk / 'lib/runtime-library').write_text('compiler dependency')
            (sdk / 'share/doc').mkdir(parents=True)
            (sdk / 'share/doc/large').write_text('not staged')
            rustc = sdk / 'bin/rustc'
            rustc.write_text('''#!/usr/bin/env python3
import os, sys
if sys.argv[1:] == ['--print', 'sysroot']: print(os.environ['TEST_SYSROOT'])
elif sys.argv[1:] == ['--version']: print('rustc ' + os.environ['TEST_RUST_VERSION'])
elif sys.argv[1:] == ['-vV']: print('host: ' + os.environ['TEST_RUST_HOST'])
else: sys.exit(1)
''')
            rustc.chmod(0o755)
            cargo = sdk / 'bin/cargo'
            cargo.write_text('#!/bin/sh\necho "cargo test-version"\n')
            cargo.chmod(0o755)
            env = dict(os.environ, PATH=f'{sdk / "bin"}:{os.environ["PATH"]}',
                       TEST_SYSROOT=str(sdk), TEST_RUST_VERSION='1.99.0',
                       TEST_RUST_HOST='x86_64-unknown-linux-gnu')
            def run():
                return subprocess.run(['bash', str(SCRIPT), str(source)], env=env,
                                      capture_output=True, text=True)
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((source / 'rust-sdk/lib/runtime-library').exists())
            self.assertFalse((source / 'rust-sdk/share/doc/large').exists())
            self.assertIn('x86_64-unknown-linux-gnu',
                          (source / 'rust-sdk/FLUXDO_TOOLCHAIN.txt').read_text())
            env['TEST_RUST_VERSION'] = '1.89.0'
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('below required 1.96', result.stderr)
            env.update(TEST_RUST_VERSION='1.99.0', TEST_RUST_HOST='aarch64-apple-darwin')
            self.assertNotEqual(run().returncode, 0)


if __name__ == '__main__':
    unittest.main()
