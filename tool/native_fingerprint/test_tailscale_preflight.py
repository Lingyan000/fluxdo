"""验证配置隔离和真实 TLS 主机名/信任检查，不申请公网证书。"""
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest

from tailscale_preflight import node_identity, public_config, socket_checks


class PreflightTest(unittest.TestCase):
    def test_public_config_rejects_missing_secret_and_output_injection(self):
        self.assertEqual(public_config({'client_id': 'public-client', 'audience': 'api.tailscale.com/example'})['client_id'], 'public-client')
        for value in ['', 'tskey-auth-example', 'tskey-client-example', 'value\naudience=other']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                public_config({'client_id': value, 'audience': 'test'})
        with self.assertRaises(ValueError):
            public_config({'client_id': 'id', 'audience': 'test', 'secret': 'not-allowed'})

    def test_node_must_be_running_and_use_own_tailnet_address(self):
        status = {'BackendState': 'Running', 'Self': {'DNSName': 'probe.tail123.ts.net.', 'TailscaleIPs': ['100.64.1.2']}}
        self.assertEqual(node_identity(status), ('probe.tail123.ts.net', '100.64.1.2'))
        for change in [{'DNSName': 'probe.example.com'}, {'TailscaleIPs': ['127.0.0.1']}]:
            with self.assertRaises(ValueError):
                node_identity({**status, 'Self': {**status['Self'], **change}})
        with self.assertRaises(ValueError):
            node_identity({**status, 'BackendState': 'NeedsLogin'})

    def test_real_sockets_reject_untrusted_or_wrong_hostname(self):
        with tempfile.TemporaryDirectory() as folder:
            cert, key = Path(folder)/'cert.pem', Path(folder)/'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=probe.test', '-addext', 'subjectAltName=DNS:probe.test',
                '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
            checks = socket_checks(cert, key, 'probe.test', '127.0.0.1', cafile=cert)
            self.assertTrue(all(checks.values()))
            with self.assertRaises(ssl.SSLCertVerificationError):
                socket_checks(cert, key, 'other.test', '127.0.0.1', cafile=cert)
            with self.assertRaises(ssl.SSLCertVerificationError):
                socket_checks(cert, key, 'probe.test', '127.0.0.1')


if __name__ == '__main__':
    unittest.main()
