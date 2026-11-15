"""验证调试入口的环境限制和失败后恢复，不连接设备。"""
import base64
from pathlib import Path
import unittest

from android_quic_control import scoped_quic_control


class Device:
    def __init__(self, original=None, serial='emulator-5554', build='userdebug'):
        self.content = original
        self.serial, self.build = serial, build
        self.calls = []

    def adb(self, *args):
        self.calls.append(args)
        if args == ('get-serialno',):
            return self.serial
        if args[:3] == ('shell', 'getprop', 'ro.build.type'):
            return self.build
        if args[0] == 'shell' and args[1].startswith('if '):
            return 'present' if self.content is not None else ''
        if args[:2] == ('shell', 'cat'):
            return self.content
        if args[0] == 'push':
            self.content = Path(args[1]).read_text()
        if args[:3] == ('shell', 'rm', '-f'):
            self.content = None
        return ''


class ScopedQuicControlTest(unittest.TestCase):
    def setUp(self):
        self.env = {'GITHUB_ACTIONS': 'true', 'FLUXDO_NATIVE_PROBE_FORCE_QUIC': '1',
                    'FLUXDO_NATIVE_PROBE_SPKI': base64.b64encode(bytes(range(32))).decode()}
        self.url = 'https://localhost:43210/fluxdo-h3'

    def test_disabled_does_not_touch_device(self):
        d = Device()
        with scoped_quic_control(d.adb, {}, self.url) as enabled:
            self.assertFalse(enabled)
        self.assertEqual(d.calls, [])

    def test_missing_runner_rejected_before_device_access(self):
        d = Device()
        self.env.pop('GITHUB_ACTIONS')
        with self.assertRaises(ValueError), scoped_quic_control(d.adb, self.env, self.url):
            pass
        self.assertEqual(d.calls, [])

    def test_non_probe_origins_rejected(self):
        for url in ['https://example.com:43210/fluxdo-h3', 'http://localhost:43210/fluxdo-h3',
                    'https://user@localhost:43210/fluxdo-h3', 'https://localhost:43210/business']:
            d = Device()
            with self.subTest(url=url), self.assertRaises(ValueError), scoped_quic_control(d.adb, self.env, url):
                pass
            self.assertEqual(d.calls, [])

    def test_invalid_spki_rejected(self):
        for value in ['', 'invalid key', base64.b64encode(b'short').decode()]:
            self.env['FLUXDO_NATIVE_PROBE_SPKI'] = value
            with self.subTest(value=value), self.assertRaises(ValueError), scoped_quic_control(Device().adb, self.env, self.url):
                pass

    def test_real_device_and_user_build_rejected(self):
        for d in [Device(serial='physical-device'), Device(build='user')]:
            with self.assertRaises(RuntimeError), scoped_quic_control(d.adb, self.env, self.url):
                pass
            self.assertFalse(any(c[0] == 'push' for c in d.calls))

    def test_new_file_is_scoped_and_removed(self):
        d = Device()
        with scoped_quic_control(d.adb, self.env, self.url) as enabled:
            self.assertTrue(enabled)
            self.assertIn('--origin-to-force-quic-on=localhost:43210 ', d.content)
            self.assertIn('--ignore-certificate-errors-spki-list=' + self.env['FLUXDO_NATIVE_PROBE_SPKI'], d.content)
            self.assertNotIn('--ignore-certificate-errors ', d.content)
        self.assertIsNone(d.content)

    def test_existing_file_restored_on_failure(self):
        original = '_ --existing-flag\n'
        d = Device(original)
        with self.assertRaisesRegex(RuntimeError, 'sample failed'):
            with scoped_quic_control(d.adb, self.env, self.url):
                raise RuntimeError('sample failed')
        self.assertEqual(d.content, original)


if __name__ == '__main__':
    unittest.main()
