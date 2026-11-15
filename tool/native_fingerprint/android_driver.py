#!/usr/bin/env python3
"""用真实 Android WebView 采样；Core 位于 Linux 宿主，须在报告中分别标注。"""
import json
import os
import subprocess
import sys
import time
from urllib.parse import urlparse

def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, timeout=20)

url = next(a for a in sys.argv[1:] if a.startswith('https://localhost:'))
port = urlparse(url).port
package = 'com.fluxdo.fingerprintprobe'
adb('reverse', f'tcp:{port}', f'tcp:{port}')
try:
    adb('shell', 'am', 'force-stop', package)
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-n', package + '/.ProbeActivity', '--es', 'url', url,
        '--es', 'mode', os.environ.get('FLUXDO_ANDROID_UA_MODE', 'native'))
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        logs = adb('logcat', '-d', '-s', 'FluxdoProbeResult:I', '*:S')
        for line in logs.splitlines():
            if '{' in line:
                result = json.loads(line[line.index('{'):])
                print(json.dumps(result), flush=True)
                raise SystemExit(0 if result.get('success') else 1)
        time.sleep(.25)
    raise RuntimeError('Android WebView probe timed out')
finally:
    adb('shell', 'am', 'force-stop', package)
    adb('reverse', '--remove', f'tcp:{port}')
