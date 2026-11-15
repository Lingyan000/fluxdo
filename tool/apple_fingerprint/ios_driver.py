#!/usr/bin/env python3
"""将回环探针地址传给已安装在模拟器中的原生 WKWebView 宿主。"""
import os
import subprocess
import sys

url = next(arg for arg in sys.argv[1:] if arg.startswith('https://localhost:'))
env = dict(os.environ)
env['SIMCTL_CHILD_FLUXDO_APPLE_UA_MODE'] = env.get('FLUXDO_APPLE_UA_MODE', 'native')
try:
    result = subprocess.run([
        'xcrun', 'simctl', 'launch', '--terminate-running-process', '--console',
        env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', url,
    ], env=env, timeout=75)
    code = result.returncode
except subprocess.TimeoutExpired:
    code = 124
finally:
    # 驱动失败也结束模拟器中的应用，避免下一轮误采上一轮迟到的握手。
    try:
        subprocess.run(['xcrun', 'simctl', 'terminate', env['FLUXDO_SIMULATOR_UDID'],
                        'org.fluxdo.fingerprint.probe'], timeout=15, capture_output=True)
    except subprocess.TimeoutExpired:
        pass
raise SystemExit(code)
