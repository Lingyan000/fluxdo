"""真机预算门槛：模拟器身份、Core 退出和服务端协议确认缺一不可。"""
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from browserstack_core import check_plan, main
from verify_public_trace import verify


class PublicTraceTest(unittest.TestCase):
    def setUp(self):
        self.report = {'success': True, 'engine': 'iOS production Core FFI', 'physical_device': False,
                       'core_running_on_ios': True, 'core_shutdown': True,
                       'native_public_trace': [{'http': 'h3'}],
                       'core_public_trace': [{'http_version': '3.0', 'trace': {'http': 'h3'}}]}

    def test_valid_and_wrong_platform(self):
        self.assertTrue(verify(self.report, False))
        self.assertFalse(verify(self.report, True))

    def test_missing_required_results_rejects(self):
        for key in self.report:
            report = copy.deepcopy(self.report)
            del report[key]
            self.assertFalse(verify(report, False), key)

    def test_local_version_does_not_replace_server_confirmation(self):
        self.report['core_public_trace'][-1]['trace']['http'] = 'http/2'
        self.assertFalse(verify(self.report, False))

    def test_no_paid_or_busy_sessions(self):
        good = {'automate_plan': 'Free', 'parallel_sessions_running': 0,
                'queued_sessions': 0, 'parallel_sessions_max_allowed': 5}
        check_plan(good)
        for field, value in [('automate_plan', 'Paid'), ('parallel_sessions_running', 1),
                             ('queued_sessions', 1), ('parallel_sessions_max_allowed', 0)]:
            with self.assertRaises(RuntimeError):
                check_plan(dict(good, **{field: value}))

    def test_observation_failure_still_releases_the_only_session(self):
        calls = []
        def factory(host, auth):
            def request(path, method='GET', body=None, **kwargs):
                calls.append((path, method))
                if path.endswith('/plan.json'):
                    return {'automate_plan': 'Free', 'parallel_sessions_running': 0,
                            'queued_sessions': 0, 'parallel_sessions_max_allowed': 1}
                if path.endswith('/devices.json'):
                    return [{'os': 'ios', 'os_version': '15', 'device': 'test-device'}]
                if path.endswith('/upload'): return {'app_url': 'bs://synthetic'}
                if path == '/wd/hub/session': return {'value': {'sessionId': 'test-session'}}
                return {}
            return request
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root/'app.ipa').write_bytes(b'synthetic')
            (root/'sim.json').write_text(json.dumps({'passed': True, 'driver': self.report}))
            args = ['probe', '--ipa', str(root/'app.ipa'), '--simulator-result', str(root/'sim.json'), '--output', str(root/'out')]
            with patch('sys.argv', args), patch('sys.stdout', io.StringIO()), \
                 patch.dict('os.environ', BROWSERSTACK_USERNAME='test', BROWSERSTACK_ACCESS_KEY='test'), \
                 patch('browserstack_core.API', side_effect=factory), \
                 patch('browserstack_core.observe', side_effect=TimeoutError('budget')):
                self.assertEqual(main(), 1)
            result = json.loads((root/'out/result.json').read_text())
            self.assertTrue(result['session_released'])
            self.assertEqual(calls.count(('/wd/hub/session', 'POST')), 1)
            self.assertEqual(calls.count(('/wd/hub/session/test-session', 'DELETE')), 1)


if __name__ == '__main__':
    unittest.main()
