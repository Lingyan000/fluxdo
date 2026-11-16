"""只操作模拟器与异常恢复网络的回归。"""
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from android_app_smoke import core_mapping_evidence, main


class AndroidAppTest(unittest.TestCase):
    def run_case(self, physical=False):
        calls = []
        disabled = False
        def adb(args, **kwargs):
            nonlocal disabled
            calls.append(args[1:])
            if args[1:] == ['shell', 'getprop', 'ro.kernel.qemu']: return b'0' if physical else b'1'
            if args[1:] == ['shell', 'svc', 'data', 'disable']: disabled = True
            if args[1:3] == ['shell', 'pidof']:
                if disabled: raise RuntimeError('app died offline')
                return b'123'
            if args[1:4] == ['shell', 'pm', 'path']: return b'package:/data/app/fixture/base.apk'
            if args[1:3] == ['shell', 'cat']:
                return b'1000-2000 r-xp 00000000 00:01 42 /data/app/fixture/lib/x86_64/libfluxdo_net.so'
            return b'1'
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with zipfile.ZipFile(root/'app.apk', 'w') as archive:
                archive.writestr('lib/x86_64/libfluxdo_net.so', b'fixture')
            argv = ['probe', '--apk', str(root/'app.apk'), '--output', str(root/'out')]
            with patch('sys.argv', argv), patch('sys.stdout', io.StringIO()), \
                 patch('android_app_smoke.subprocess.check_output', side_effect=adb), \
                 patch('android_app_smoke.time.sleep'):
                self.assertEqual(main(), 1)
            result = json.loads((root/'out/result.json').read_text())
        return calls, result

    def test_physical_device_is_never_modified_or_stopped(self):
        calls, result = self.run_case(physical=True)
        self.assertEqual(calls, [['shell', 'getprop', 'ro.kernel.qemu']])
        self.assertFalse(result.get('app_stopped', False))

    def test_network_and_process_cleanup_after_offline_failure(self):
        calls, result = self.run_case()
        self.assertIn(['shell', 'svc', 'wifi', 'enable'], calls)
        self.assertIn(['shell', 'svc', 'data', 'enable'], calls)
        self.assertTrue(result['network_restored'])
        self.assertTrue(result['app_stopped'])

    def test_apk_mapping_requires_executable_bytes_inside_the_core_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder)/'app.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('lib/x86_64/libother.so', bytes(4096))
                archive.writestr('lib/x86_64/libfluxdo_net.so', bytes(8192))
            with zipfile.ZipFile(apk) as archive:
                info = archive.getinfo('lib/x86_64/libfluxdo_net.so')
                offset = info.header_offset + 30 + len(info.filename.encode())
            installed = '/data/app/fixture/base.apk'
            def row(offset, mode='r-xp', path=installed):
                return f'1000-2000 {mode} {offset:08x} 00:01 42 {path}'
            evidence = core_mapping_evidence(row(offset), apk, [installed])
            self.assertEqual(evidence['kind'], 'apk_entry')
            self.assertIsNone(core_mapping_evidence(row(0), apk, [installed]))
            self.assertIsNone(core_mapping_evidence(row(offset+8192), apk, [installed]))
            self.assertIsNone(core_mapping_evidence(row(offset, 'r--p'), apk, [installed]))
            self.assertIsNone(core_mapping_evidence(row(offset, path='/data/app/other/base.apk'), apk, [installed]))

    def test_compressed_apk_bytes_are_not_a_loaded_library(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder)/'app.apk'
            with zipfile.ZipFile(apk, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('lib/x86_64/libfluxdo_net.so', bytes(8192))
            installed = '/data/app/fixture/base.apk'
            row = '1000-2000 r-xp 00000040 00:01 42 '+installed
            self.assertIsNone(core_mapping_evidence(row, apk, [installed]))


if __name__ == '__main__':
    unittest.main()
