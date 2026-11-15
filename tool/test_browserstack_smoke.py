"""离线验证计时会话的释放与失败后不重试，不连接 BrowserStack。"""
from pathlib import Path
import tempfile
import unittest

from browserstack_smoke import capture, verify_plan


class BudgetTests(unittest.TestCase):
    def test_reject_paid_busy_or_missing_plan(self):
        baseline = {'automate_plan': 'Free', 'parallel_sessions_running': 0,
                    'parallel_sessions_max_allowed': 5, 'queued_sessions': 0}
        verify_plan(baseline)
        for patch in ({'automate_plan': 'Paid'}, {'parallel_sessions_running': 1},
                      {'queued_sessions': 1}, {'parallel_sessions_max_allowed': 0}):
            with self.assertRaises(RuntimeError):
                verify_plan(baseline | patch)
        with self.assertRaises(RuntimeError):
            verify_plan({})

    def test_screenshot_failure_still_releases_single_session(self):
        calls = []

        def hub(path, method='GET', body=None, **kwargs):
            calls.append((method, path))
            if method == 'POST':
                self.assertEqual(body['capabilities']['alwaysMatch']['bstack:options']['idleTimeout'], 30)
                return {'value': {'sessionId': 'abc123'}}
            if path.endswith('current_package'):
                return {'value': 'com.github.lingyan000.fluxdo'}
            if path.endswith('screenshot'):
                raise TimeoutError('simulated screenshot timeout')
            if method == 'DELETE':
                return {}
            self.fail('Unexpected request: ' + path)

        report = {}
        with tempfile.TemporaryDirectory() as folder, self.assertRaises(TimeoutError):
            capture(None, hub, Path(folder), 'bs://test',
                    {'device': 'device', 'os_version': '16'}, report)
        self.assertTrue(report['session_released'])
        self.assertEqual(sum(method == 'POST' for method, _ in calls), 1)
        self.assertEqual(calls[-1], ('DELETE', '/wd/hub/session/abc123'))

    def test_session_creation_timeout_is_not_retried(self):
        calls = []

        def hub(path, method='GET', body=None, **kwargs):
            calls.append((method, path))
            raise TimeoutError('simulated create timeout')

        report = {}
        with tempfile.TemporaryDirectory() as folder, self.assertRaises(TimeoutError):
            capture(None, hub, Path(folder), 'bs://test',
                    {'device': 'device', 'os_version': '16'}, report)
        self.assertEqual(calls, [('POST', '/wd/hub/session')])
        self.assertNotIn('session_released', report)


if __name__ == '__main__':
    unittest.main()
