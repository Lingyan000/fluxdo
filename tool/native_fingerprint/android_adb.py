"""诊断取证断连恢复：仅重试读取，不重放页面或网络请求。"""
from pathlib import Path
import subprocess
import sys


def capture_netlog(path):
    target = Path(path)
    for attempt in range(2):
        result = subprocess.run(['adb', 'shell', 'run-as', 'com.fluxdo.fingerprintprobe', 'cat',
                                 'files/probe-netlog.json'], text=True, capture_output=True, timeout=20)
        if result.returncode == 0:
            target.write_text(result.stdout)
            return
        # 断连时也保留收到的前缀；不能用后续成功读取消除首次失败证据。
        if result.stdout:
            target.with_name(target.stem + f'-read-{attempt + 1}.partial.json').write_text(result.stdout)
        target.with_name(target.stem + f'-read-{attempt + 1}.stderr').write_text(result.stderr)
        if attempt == 0 and 'device offline' in result.stderr:
            sys.stderr.write('NetLog read disconnected; one bounded adb reconnect, no navigation retry\n')
            subprocess.run(['adb', 'wait-for-device'], check=True, timeout=10,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            continue
        raise subprocess.CalledProcessError(result.returncode, result.args, stderr=result.stderr)
