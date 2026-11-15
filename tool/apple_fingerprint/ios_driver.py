#!/usr/bin/env python3
"""将回环探针地址传给已安装在模拟器中的原生 WKWebView 宿主。"""
import os
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

warmup = '--warmup' in sys.argv
target = '--warmup' if warmup else next(arg for arg in sys.argv[1:] if arg.startswith('https://localhost:'))
env = dict(os.environ)
env['SIMCTL_CHILD_FLUXDO_APPLE_UA_MODE'] = env.get('FLUXDO_APPLE_UA_MODE', 'native')
env['SIMCTL_CHILD_FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST'] = env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST', '0')
report_name = 'fluxdo-report-' + uuid.uuid4().hex + '.json'
env['SIMCTL_CHILD_FLUXDO_APPLE_REPORT_FILE'] = report_name
try:
    report_timeout = 110 if warmup else 75
    deadline = time.monotonic() + report_timeout
    if env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST') == '1':
        # 仅一次性 CI 模拟器；run.py 创建并最终删除此设备，不改用户设备信任库。
        if env.get('GITHUB_ACTIONS') != 'true':
            raise RuntimeError('system-trust experiment requires an ephemeral GitHub runner')
        subprocess.run(['xcrun', 'simctl', 'keychain', env['FLUXDO_SIMULATOR_UDID'],
                        'add-root-cert', env['FLUXDO_APPLE_LAB_CA']], check=True, timeout=30)
    result = subprocess.run([
        'xcrun', 'simctl', 'launch', '--terminate-running-process',
        env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', target,
    ], env=env, timeout=25, capture_output=True, text=True)
    # 不附着可能阻塞的 simctl 控制台；退出结果由本次启动的独立文件核验。
    sys.stderr.write(result.stdout)
    sys.stderr.write(result.stderr)
    code = result.returncode
    if code:
        raise RuntimeError('simctl launch failed: ' + str(code))
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
        env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', 'data'], text=True, timeout=15).strip()
    report_path = Path(container) / 'tmp' / report_name
    while not report_path.exists() and time.monotonic() < deadline:
        time.sleep(0.25)
    if not report_path.exists():
        raise subprocess.TimeoutExpired(['native WKWebView report'], report_timeout)
    report = json.loads(report_path.read_text())
    if report.get('engine') != 'native WKWebView' or report.get('success') is not True:
        code = code or 1
    print(json.dumps(report), flush=True)
    report_path.unlink()
except subprocess.TimeoutExpired as error:
    print('原生宿主命令超时: ' + str(error), file=sys.stderr, flush=True)
    code = 124
except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
    print('原生宿主结果不完整: ' + str(error), file=sys.stderr, flush=True)
    code = 1
finally:
    # 驱动失败也结束模拟器中的应用，避免下一轮误采上一轮迟到的握手。
    try:
        subprocess.run(['xcrun', 'simctl', 'terminate', env['FLUXDO_SIMULATOR_UDID'],
                        'org.fluxdo.fingerprint.probe'], timeout=15, capture_output=True)
    except subprocess.TimeoutExpired:
        pass
raise SystemExit(code)
