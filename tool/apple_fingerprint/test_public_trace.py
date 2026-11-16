"""真机预算门槛：模拟器身份、Core 退出和服务端协议确认缺一不可。"""
import copy
import unittest

from browserstack_core import check_plan
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


if __name__ == '__main__':
    unittest.main()
