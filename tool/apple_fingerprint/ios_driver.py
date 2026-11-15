#!/usr/bin/env python3
"""将回环探针地址传给已安装在模拟器中的原生 WKWebView 宿主。"""
import os
import subprocess
import sys

url = next(arg for arg in sys.argv[1:] if arg.startswith('https://localhost:'))
env = dict(os.environ)
env['SIMCTL_CHILD_FLUXDO_APPLE_UA_MODE'] = env.get('FLUXDO_APPLE_UA_MODE', 'native')
result = subprocess.run([
    'xcrun', 'simctl', 'launch', '--terminate-running-process', '--console',
    env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', url,
], env=env, timeout=35)
raise SystemExit(result.returncode)
