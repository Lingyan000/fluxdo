#!/usr/bin/env python3
"""用真实 Android WebView 采样；Core 位于 Linux 宿主，须在报告中分别标注。"""
import json
import os
import subprocess
import sys
import time
from urllib.parse import urlparse
from android_quic_control import scoped_quic_control

def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, timeout=20)

url = next(a for a in sys.argv[1:] if a.startswith('https://localhost:'))
port = urlparse(url).port
package = 'com.fluxdo.fingerprintprobe'
adb('reverse', f'tcp:{port}', f'tcp:{port}')
try:
    with scoped_quic_control(adb, os.environ, url) as forced:
        try:
            adb('shell', 'am', 'force-stop', package)
            if forced:
                adb('shell', 'run-as', package, 'rm', '-f', 'files/probe-netlog.json')
            adb('logcat', '-c')
            adb('shell', 'am', 'start', '-W', '-n', package + '/.ProbeActivity', '--es', 'url', url,
                '--es', 'mode', os.environ.get('FLUXDO_ANDROID_UA_MODE', 'native'),
                '--ez', 'udpBridge', 'true' if os.environ.get('FLUXDO_ANDROID_H3_RELAY')=='1' else 'false')
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                logs = adb('logcat', '-d', '-s', 'FluxdoProbeResult:I', '*:S')
                for line in logs.splitlines():
                    if '{' in line:
                        result = json.loads(line[line.index('{'):])
                        result['diagnostic_force_quic'] = forced
                        print(json.dumps(result), flush=True)
                        raise SystemExit(0 if result.get('success') else 1)
                time.sleep(.25)
            raise RuntimeError('Android WebView probe timed out')
        finally:
            try:
                if forced:
                    # 此宿主没有业务登录；保留参数读取、解析和 SELinux 错误，避免按错误标签漏采。
                    logs = adb('logcat', '-d')
                    sys.stderr.write('\n'.join(line for line in logs.splitlines() if any(
                        key in line.lower() for key in ('chromium', 'commandline', 'avc:', 'net::'))) + '\n')
                    netlog = subprocess.run(['adb', 'shell', 'run-as', package, 'cat',
                        'files/probe-netlog.json'], text=True, capture_output=True, timeout=20)
                    path = os.environ.get('FLUXDO_NATIVE_NETLOG_PATH')
                    if path and netlog.returncode == 0:
                        from pathlib import Path
                        Path(path).write_text(netlog.stdout)
                    else:
                        sys.stderr.write('probe-netlog unavailable: ' + netlog.stderr + netlog.stdout[:300])
            finally:
                adb('shell', 'am', 'force-stop', package)
finally:
    adb('reverse', '--remove', f'tcp:{port}')
