#!/usr/bin/env python3
"""将回环探针地址传给已安装在模拟器中的原生 WKWebView 宿主。"""
import os
import json
from pathlib import Path
import subprocess
import sys
import uuid

url = next(arg for arg in sys.argv[1:] if arg.startswith('https://localhost:'))
env = dict(os.environ)
env['SIMCTL_CHILD_FLUXDO_APPLE_UA_MODE'] = env.get('FLUXDO_APPLE_UA_MODE', 'native')
env['SIMCTL_CHILD_FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST'] = env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST', '0')
report_name = 'fluxdo-report-' + uuid.uuid4().hex + '.json'
env['SIMCTL_CHILD_FLUXDO_APPLE_REPORT_FILE'] = report_name
try:
    if env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST') == '1':
        # 仅一次性 CI 模拟器；run.py 创建并最终删除此设备，不改用户设备信任库。
        if env.get('GITHUB_ACTIONS') != 'true':
            raise RuntimeError('system-trust experiment requires an ephemeral GitHub runner')
        subprocess.run(['xcrun', 'simctl', 'keychain', env['FLUXDO_SIMULATOR_UDID'],
                        'add-root-cert', env['FLUXDO_APPLE_LAB_CA']], check=True, timeout=30)
    result = subprocess.run([
        'xcrun', 'simctl', 'launch', '--terminate-running-process', '--console',
        env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', url,
    ], env=env, timeout=75, capture_output=True, text=True)
    # 原始控制台保留在 stderr，stdout 只发布文件中完整的一份宿主结果。
    sys.stderr.write(result.stdout)
    sys.stderr.write(result.stderr)
    code = result.returncode
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
        env['FLUXDO_SIMULATOR_UDID'], 'org.fluxdo.fingerprint.probe', 'data'], text=True, timeout=15).strip()
    report_path = Path(container) / 'tmp' / report_name
    report = json.loads(report_path.read_text())
    if report.get('engine') != 'native WKWebView' or report.get('success') is not True:
        code = code or 1
    print(json.dumps(report), flush=True)
    report_path.unlink()
except subprocess.TimeoutExpired:
    code = 124
except (OSError, ValueError, subprocess.CalledProcessError) as error:
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
