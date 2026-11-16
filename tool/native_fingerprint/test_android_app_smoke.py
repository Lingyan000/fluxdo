"""只操作模拟器与异常恢复网络的回归。"""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from android_app_smoke import main


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
            if args[1:3] == ['shell', 'cat']: return b'libfluxdo_net.so'
            return b'1'
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);(root/'app.apk').write_bytes(b'fixture')
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


if __name__ == '__main__':
    unittest.main()
