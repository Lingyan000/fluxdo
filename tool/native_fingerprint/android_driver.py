#!/usr/bin/env python3
"""用真实 Android WebView 采样；Core 位于 Linux 宿主，须在报告中分别标注。"""
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlparse
from android_quic_control import scoped_quic_control
from android_adb import capture_netlog

def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, timeout=20)

url = next(a for a in sys.argv[1:] if a.startswith('https://'))
target = urlparse(url)
trusted_host = os.environ.get('FLUXDO_TRUSTED_PROBE_HOST', '')
trusted = (bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.[a-z0-9-]+\.ts\.net', trusted_host))
           and target.hostname == trusted_host)
if (target.hostname != 'localhost' and not trusted) or target.username or target.password or not target.port:
    raise ValueError('Only local or explicitly configured tailnet probe is allowed')
if trusted and (os.environ.get('FLUXDO_NATIVE_PROBE_FORCE_QUIC') == '1' or os.environ.get('FLUXDO_ANDROID_H3_RELAY') == '1'):
    raise ValueError('Trusted probe forbids forced QUIC and loopback relay')
port = target.port
package = 'com.fluxdo.fingerprintprobe'
if not trusted:
    adb('reverse', f'tcp:{port}', f'tcp:{port}')
try:
    with scoped_quic_control(adb, os.environ, url) as forced:
        logging = forced or (os.environ.get('FLUXDO_NATIVE_PROBE_NETLOG') == '1'
                             and bool(os.environ.get('FLUXDO_NATIVE_NETLOG_PATH')))
        try:
            adb('shell', 'am', 'force-stop', package)
            if logging:
                adb('shell', 'run-as', package, 'mkdir', '-p', 'files')
                adb('shell', 'run-as', package, 'rm', '-f', 'files/probe-netlog.json')
            adb('logcat', '-c')
            adb('shell', 'am', 'start', '-W', '-n', package + '/.ProbeActivity', '--es', 'url', url,
                '--es', 'mode', os.environ.get('FLUXDO_ANDROID_UA_MODE', 'native'),
                '--es', 'trustedHost', trusted_host if trusted else 'none',
                '--ez', 'udpBridge', 'true' if os.environ.get('FLUXDO_ANDROID_H3_RELAY')=='1' else 'false')
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                logs = adb('logcat', '-d', '-s', 'FluxdoProbeResult:I', '*:S')
                for line in logs.splitlines():
                    if '{' in line:
                        result = json.loads(line[line.index('{'):])
                        result['diagnostic_force_quic'] = forced
                        result['diagnostic_netlog'] = logging
                        print(json.dumps(result), flush=True)
                        raise SystemExit(0 if result.get('success') else 1)
                time.sleep(.25)
            raise RuntimeError('Android WebView probe timed out')
        finally:
            try:
                if logging:
                    # 此宿主没有业务登录；保留参数读取、解析和 SELinux 错误，避免按错误标签漏采。
                    logs = adb('logcat', '-d')
                    sys.stderr.write('\n'.join(line for line in logs.splitlines() if any(
                        key in line.lower() for key in ('chromium', 'commandline', 'avc:', 'net::'))) + '\n')
                    path = os.environ.get('FLUXDO_NATIVE_NETLOG_PATH')
                    if path:
                        capture_netlog(path)
            finally:
                adb('shell', 'am', 'force-stop', package)
finally:
    if not trusted:
        adb('reverse', '--remove', f'tcp:{port}')
