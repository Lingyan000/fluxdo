"""完整 App 验证的身份、单次创建和异常清理回归。"""
import base64
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from browserstack_app_smoke import application_identity, main


class FullAppTest(unittest.TestCase):
    def ipa(self, root, bundle='com.github.lingyan000.fluxdo'):
        path = root/'app.ipa'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Runner.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': bundle}))
        return path

    def test_rejects_diagnostic_app_before_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                application_identity(self.ipa(Path(folder), 'org.fluxdo.fingerprint.core'))

    def scenario(self, source_error=False, fail_creation=False, active='com.github.lingyan000.fluxdo'):
        calls = []
        def factory(host, auth):
            def request(path, method='GET', body=None, **kwargs):
                calls.append((path, method))
                if path.endswith('/plan.json'):
                    return {'automate_plan': 'Free', 'parallel_sessions_running': 0,
                            'queued_sessions': 0, 'parallel_sessions_max_allowed': 1}
                if path.endswith('/devices.json'):
                    return [{'os': 'ios', 'os_version': '26', 'device': 'iPhone test'}]
                if path.endswith('/upload'): return {'app_url': 'bs://synthetic'}
                if path == '/wd/hub/session':
                    if fail_creation: raise TimeoutError('unknown creation')
                    return {'value': {'sessionId': 'test-session'}}
                if path.endswith('/execute/sync'): return {'value': {'bundleId': active}}
                if path.endswith('/source'):
                    if source_error: raise TimeoutError('source')
                    return {'value': '<XCUIElementTypeApplication/>'}
                if path.endswith('/screenshot'): return {'value': base64.b64encode(b'image').decode()}
                return {}
            return request
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = ['probe', '--ipa', str(self.ipa(root)), '--output', str(root/'out')]
            with patch('sys.argv', args), patch('sys.stdout', io.StringIO()), \
                 patch.dict('os.environ', BROWSERSTACK_USERNAME='test', BROWSERSTACK_ACCESS_KEY='test'), \
                 patch('browserstack_app_smoke.API', side_effect=factory), \
                 patch('browserstack_app_smoke.time.sleep'):
                code = main()
            result = json.loads((root/'out/result.json').read_text())
        self.assertEqual(calls.count(('/wd/hub/session', 'POST')), 1)
        return code, result, calls

    def test_launch_pass_requires_expected_foreground_application(self):
        code, result, _ = self.scenario()
        self.assertEqual(code, 0)
        self.assertTrue(result['session_released'])
        code, result, _ = self.scenario(active='com.apple.springboard')
        self.assertEqual(code, 1)
        self.assertTrue(result['session_released'])

    def test_failure_after_creation_always_releases(self):
        code, result, calls = self.scenario(source_error=True)
        self.assertEqual(code, 1)
        self.assertTrue(result['session_released'])
        self.assertEqual(calls.count(('/wd/hub/session/test-session', 'DELETE')), 1)

    def test_unknown_creation_is_not_retried_or_claimed_released(self):
        code, result, calls = self.scenario(fail_creation=True)
        self.assertEqual(code, 1)
        self.assertFalse(result['session_released'])
        self.assertIn('Unknown', result['creation_outcome'])
        self.assertFalse(any(method == 'DELETE' for _, method in calls))


if __name__ == '__main__':
    unittest.main()
