"""可信入口必须同时有原生证书证据、完整 H3 抓包和无豁免命令行。"""
import json
from pathlib import Path
import tempfile
import unittest

from tailscale_h3 import CASES, audit


class TrustedAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.host = 'node.tailnet.ts.net'
        self.driver = {'success': True, 'trusted_certificate_required': True, 'ssl_errors_proceeded': 0,
                       'ssl_error_count': 0, 'udp_relay': False, 'diagnostic_force_quic': False}
        self.capture = {'trusted_origin': True, 'spki_override': False, 'joint_capture_complete': True,
                        'tcp_requests': [{}], 'h3': [{'path': '/fluxdo-probe/qpack/'+name} for name in CASES]}
        self.netlog = {'constants': {'logEventTypes': {'CERT_VERIFIER_JOB': 1}}, 'events': [
            {'type': 1, 'source': {'id': 1}, 'params': {'host': self.host}},
            {'type': 1, 'source': {'id': 1}, 'params': {'cert_status': 0, 'is_issued_by_known_root': True}}]}
        self.flags = 'COMMAND-LINE FLAGS: _ --log-net-log=probe.json\n'

    def check(self, negative=False):
        for name, value in [('h3-capture.json', self.capture), ('browser.stdout', self.driver),
                            ('browser-netlog.json', self.netlog)]:
            (self.folder/name).write_text(json.dumps(value))
        (self.folder/'browser.stderr').write_text(self.flags)
        return audit(self.folder, self.host, negative)['passed']

    def test_apple_requires_actual_system_evaluation_without_credentials(self):
        self.driver.update(engine='native WKWebView', system_trust_evaluations=[
            {'hostname': self.host, 'system_trusted': True}])
        self.assertTrue(self.check())
        self.driver['system_trust_evaluations'] = []
        self.assertFalse(self.check())
        self.driver['system_trust_evaluations'] = [{'hostname': 'other.ts.net', 'system_trusted': True}]
        self.assertFalse(self.check())
        self.driver.update(success=False, certificate_rejected=True, ssl_error_count=1,
                           system_trust_evaluations=[{'hostname': self.host, 'system_trusted': False}])
        self.capture.update(h3=[], tcp_requests=[], joint_capture_complete=False)
        self.assertTrue(self.check(negative=True))
        self.driver['ssl_errors_proceeded'] = 1
        self.assertFalse(self.check(negative=True))

    def test_windows_requires_actual_flags_and_shared_main_lifecycle(self):
        self.driver.update(engine='Flutter WebView2 production probe environment',
                           environment_kind='shared_main', main_survived=True,
                           main_profile_removed=True, isolated_h3_environment=False)
        self.flags = ''
        self.netlog['constants']['clientInfo'] = {'command_line': 'msedgewebview2.exe --log-net-log=probe.json'}
        self.assertTrue(self.check())
        self.netlog['constants']['clientInfo']['command_line'] += ' --ignore-certificate-errors'
        self.assertFalse(self.check())
        self.netlog['constants']['clientInfo']['command_line'] = 'msedgewebview2.exe --log-net-log=probe.json'
        self.driver['main_profile_removed'] = False
        self.assertFalse(self.check())

    def test_default_h3_requires_all_evidence(self):
        self.assertTrue(self.check())
        self.driver['ssl_errors_proceeded'] = 1
        self.assertFalse(self.check())
        self.driver['ssl_errors_proceeded'] = 0
        self.capture['joint_capture_complete'] = False
        self.assertFalse(self.check())

    def test_other_host_certificate_cannot_prove_target_trust(self):
        self.netlog['events'][0]['params']['host'] = 'other.tailnet.ts.net'
        self.assertFalse(self.check())

    def test_override_and_missing_scenario_fail(self):
        for flag in ('--origin-to-force-quic-on=x', '--ignore-certificate-errors', '--host-resolver-rules=x'):
            self.flags = 'COMMAND-LINE FLAGS: _ --log-net-log=probe.json '+flag
            self.assertFalse(self.check())
        self.flags = 'COMMAND-LINE FLAGS: _ --log-net-log=probe.json'
        self.capture['h3'].pop()
        self.assertFalse(self.check())

    def test_negative_requires_certificate_failure_and_zero_requests(self):
        self.driver.update(success=False, ssl_error_count=1, error='certificate 3')
        self.capture.update(h3=[], tcp_requests=[], joint_capture_complete=False)
        self.netlog['events'][1]['params'].update(cert_status=4, is_issued_by_known_root=False, net_error=-202)
        self.assertTrue(self.check(negative=True))
        self.capture['tcp_requests'] = [{}]
        self.assertFalse(self.check(negative=True))
        self.capture['tcp_requests'] = []
        self.driver['error'] = 'timeout'
        self.assertFalse(self.check(negative=True))


if __name__ == '__main__':
    unittest.main()
