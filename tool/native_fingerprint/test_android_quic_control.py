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

    def test_trusted_origin_logging_never_forces_quic_or_trust(self):
        env = {'GITHUB_ACTIONS': 'true', 'FLUXDO_NATIVE_PROBE_NETLOG': '1',
               'FLUXDO_NATIVE_NETLOG_PATH': '/tmp/capture.json',
               'FLUXDO_TRUSTED_PROBE_HOST': 'node.tailnet.ts.net'}
        d = Device()
        with scoped_quic_control(d.adb, env, 'https://node.tailnet.ts.net:43210/fluxdo-probe') as enabled:
            self.assertFalse(enabled)
            self.assertIn('--log-net-log=', d.content)
            for flag in ('--host-resolver-rules', '--origin-to-force-quic-on', '--ignore-certificate-errors'):
                self.assertNotIn(flag, d.content)
        self.assertIsNone(d.content)
        env.update(self.env)
        with self.assertRaises(ValueError), scoped_quic_control(d.adb, env, 'https://node.tailnet.ts.net:43210/fluxdo-probe'):
            pass
        env['FLUXDO_NATIVE_PROBE_FORCE_QUIC'] = '0'
        with self.assertRaises(ValueError), scoped_quic_control(d.adb, env, 'https://other.tailnet.ts.net:43210/fluxdo-probe'):
            pass

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

    def test_logging_only_keeps_default_network_and_trust(self):
        env = {'GITHUB_ACTIONS': 'true', 'FLUXDO_NATIVE_PROBE_NETLOG': '1',
               'FLUXDO_NATIVE_NETLOG_PATH': '/tmp/capture.json'}
        d = Device('_ --old-flag\n')
        with scoped_quic_control(d.adb, env, self.url) as forced:
            self.assertFalse(forced)
            self.assertEqual(d.content, '_ --webview-verbose-logging '
                '--log-net-log=/data/data/com.fluxdo.fingerprintprobe/files/probe-netlog.json\n')
        self.assertEqual(d.content, '_ --old-flag\n')

    def test_logging_only_requires_ci_and_debuggable_emulator(self):
        env = {'GITHUB_ACTIONS': 'true', 'FLUXDO_NATIVE_PROBE_NETLOG': '1',
               'FLUXDO_NATIVE_NETLOG_PATH': '/tmp/capture.json'}
        for device, settings, error in [(Device(), {**env, 'GITHUB_ACTIONS': 'false'}, ValueError),
                (Device(build='user'), env, RuntimeError),
                (Device(serial='physical-device'), env, RuntimeError)]:
            with self.subTest(settings=settings, device=device.serial):
                with self.assertRaises(error), scoped_quic_control(device.adb, settings, self.url):
                    pass
                self.assertFalse(any(call[0] == 'push' for call in device.calls))

    def test_logging_without_output_does_not_change_tcp_probe(self):
        d = Device()
        with scoped_quic_control(d.adb, {'FLUXDO_NATIVE_PROBE_NETLOG': '1'}, self.url) as forced:
            self.assertFalse(forced)
        self.assertEqual(d.calls, [])


if __name__ == '__main__':
    unittest.main()
