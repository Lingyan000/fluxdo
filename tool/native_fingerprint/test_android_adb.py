"""断连恢复不得重放导航、丢失失败证据或将连续失败算作成功。"""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from android_adb import capture_netlog


class CaptureTest(unittest.TestCase):
    def test_offline_read_preserves_prefix_and_only_retries_read(self):
        with tempfile.TemporaryDirectory() as tmp, patch('android_adb.subprocess.run') as run:
            path = Path(tmp)/'browser-netlog.json'
            run.side_effect = [subprocess.CompletedProcess(['adb'], 1, '{"events":[', 'adb: device offline'),
                               subprocess.CompletedProcess(['adb'], 0),
                               subprocess.CompletedProcess(['adb'], 0, '{"events":[]}', '')]
            capture_netlog(path)
            self.assertEqual(path.read_text(), '{"events":[]}')
            self.assertEqual(path.with_name('browser-netlog-read-1.partial.json').read_text(), '{"events":[')
            self.assertEqual([call.args[0][1] for call in run.call_args_list], ['shell', 'wait-for-device', 'shell'])
            self.assertEqual(run.call_args_list[1].kwargs['timeout'], 10)
            self.assertTrue(all('start' not in call.args[0] for call in run.call_args_list))

    def test_repeated_failure_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp, patch('android_adb.subprocess.run') as run:
            path = Path(tmp)/'browser-netlog.json'
            failure = subprocess.CompletedProcess(['adb'], 1, '', 'adb: device offline')
            run.side_effect = [failure, subprocess.CompletedProcess(['adb'], 0), failure]
            with self.assertRaises(subprocess.CalledProcessError):
                capture_netlog(path)
            self.assertFalse(path.exists())
            self.assertEqual(run.call_count, 3)

    def test_other_failure_is_not_retried(self):
        with tempfile.TemporaryDirectory() as tmp, patch('android_adb.subprocess.run') as run:
            run.return_value = subprocess.CompletedProcess(['adb'], 1, '', 'Permission denied')
            with self.assertRaises(subprocess.CalledProcessError):
                capture_netlog(Path(tmp)/'netlog.json')
            self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()
