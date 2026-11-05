"""Exercise runner bookkeeping and bounded shutdown without Docker or network access."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from run_interop import verify_image_backend


class BackendSelectionTests(unittest.TestCase):
    def test_matching_image_backend(self):
        for backend in ("boring", "rustls-ring", "rustls-aws-lc"):
            verify_image_backend({"Config": {"Labels": {"org.ramaproxy.quic.tls-backend": backend}}}, backend)

    def test_wrong_or_unlabelled_images_are_rejected(self):
        for config in ({}, {"Labels": None}, {"Labels": {"org.ramaproxy.quic.tls-backend": "rustls-ring"}}):
            with self.subTest(config=config), self.assertRaisesRegex(RuntimeError, "does not match requested"):
                verify_image_backend({"Config": config}, "boring")


@unittest.skipUnless(os.name == "posix", "runner requires POSIX process groups")
class RunnerShutdownTests(unittest.TestCase):
    def test_signal_stops_child_before_returning(self):
        with tempfile.TemporaryDirectory() as temp:
            ready = Path(temp) / "ready"
            stopped = Path(temp) / "stopped"
            child = (
                "import signal,time; from pathlib import Path; "
                f"signal.signal(signal.SIGTERM, lambda *_: (Path({str(stopped)!r}).touch(), exit(0))); "
                f"Path({str(ready)!r}).touch(); time.sleep(30)"
            )
            launcher = (
                "import signal,sys; from run_interop import compose_override, inspect_image, run_managed, snapshot_container_logs\n"
                "def stop(*_): raise KeyboardInterrupt()\n"
                "signal.signal(signal.SIGTERM, stop)\n"
                f"run_managed([sys.executable, '-c', {child!r}])\n"
            )
            env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent))
            process = subprocess.Popen([sys.executable, "-c", launcher], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "fake child did not start")
                process.send_signal(signal.SIGTERM)
                self.assertNotEqual(process.wait(timeout=5), 0)
                self.assertTrue(stopped.exists(), "child survived runner interruption")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_simulator_joins_capture_children_before_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "capture.sh").write_text(
                "#!/bin/bash\n"
                "trap 'sleep 0.05; touch flushed; exit 0' TERM\n"
                "touch ready\nsleep 0.25\ntouch delivered\nwhile true; do sleep 0.01; done\n"
            )
            (root / "run.sh").write_text(
                '#!/bin/bash\nset -e\nbash ./capture.sh &\nPID=$!\n'
                'trap "kill -SIGINT $PID" INT\n'
                'trap "kill -SIGTERM $PID" TERM\nwait\n'
            )
            script = Path(__file__).resolve().parent / "run_simulator.sh"
            process = subprocess.Popen(["bash", str(script)], cwd=root, start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not (root / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "ready").exists(), "fake capture did not start")
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=5)
                self.assertTrue((root / "delivered").exists(), "capture stopped before its pending packet batch")
                self.assertTrue((root / "flushed").exists(), "simulator exited before capture flush")
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
