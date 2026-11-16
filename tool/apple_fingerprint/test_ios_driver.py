"""复现模拟器首次启动期间容器查询服务阻塞的回归。"""
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class IOSDriverTest(unittest.TestCase):
    def test_container_is_resolved_before_busy_first_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            container = Path(folder)
            (container/'tmp').mkdir()
            launched = False

            def locate(command, **kwargs):
                if launched:
                    raise subprocess.TimeoutExpired(command, 15)
                return str(container)+'\n'

            class Launch:
                returncode = 0
                def __init__(self, command, **kwargs):
                    nonlocal launched
                    launched = True
                    self.report = container/'tmp'/kwargs['env']['SIMCTL_CHILD_FLUXDO_APPLE_REPORT_FILE']
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def communicate(self, **kwargs):
                    self.report.write_text(json.dumps({'engine': 'native WKWebView', 'success': True, 'warmup': True}))
                    return 'org.fluxdo.fingerprint.probe: 123\n', ''

            with patch.dict('os.environ', {'FLUXDO_SIMULATOR_UDID': 'test-device'}, clear=True), \
                 patch('sys.argv', ['ios_driver.py', '--warmup']), \
                 patch('subprocess.check_output', side_effect=locate), \
                 patch('subprocess.Popen', Launch), patch('subprocess.run') as cleanup, \
                 contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as end:
                    runpy.run_path(str(Path(__file__).with_name('ios_driver.py')), run_name='__main__')
                self.assertEqual(end.exception.code, 0)
                self.assertTrue(json.loads(output.getvalue())['success'])
                self.assertIn('terminate', cleanup.call_args.args[0])
                self.assertEqual(list((container/'tmp').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
