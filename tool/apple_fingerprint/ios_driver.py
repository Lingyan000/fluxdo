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
core_driver = os.environ.get('FLUXDO_APPLE_CORE_DRIVER') == '1'
app_id = 'org.fluxdo.fingerprint.core' if core_driver else 'org.fluxdo.fingerprint.probe'
target = '--warmup' if warmup else next(arg for arg in sys.argv[1:] if arg.startswith('https://'))
env = dict(os.environ)
env['SIMCTL_CHILD_FLUXDO_TRUSTED_PROBE_HOST'] = env.get('FLUXDO_TRUSTED_PROBE_HOST', '')
env['SIMCTL_CHILD_FLUXDO_APPLE_UA_MODE'] = env.get('FLUXDO_APPLE_UA_MODE', 'native')
env['SIMCTL_CHILD_FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST'] = env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST', '0')
report_name = 'fluxdo-report-' + uuid.uuid4().hex + '.json'
env['SIMCTL_CHILD_FLUXDO_APPLE_REPORT_FILE'] = report_name
try:
    report_timeout = 160 if warmup else (185 if core_driver else 75)
    deadline = time.monotonic() + report_timeout
    if env.get('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST') == '1' and not env.get('FLUXDO_TRUSTED_PROBE_HOST'):
        # 仅一次性 CI 模拟器；run.py 创建并最终删除此设备，不改用户设备信任库。
        if env.get('GITHUB_ACTIONS') != 'true':
            raise RuntimeError('system-trust experiment requires an ephemeral GitHub runner')
        subprocess.run(['xcrun', 'simctl', 'keychain', env['FLUXDO_SIMULATOR_UDID'],
                        'add-root-cert', env['FLUXDO_APPLE_LAB_CA']], check=True, timeout=30)
    launch_command = [
        'xcrun', 'simctl', 'launch', '--terminate-running-process',
        env['FLUXDO_SIMULATOR_UDID'], app_id, target,
    ]
    # 首次启动会同时拉起 UIKit 与 WebContent；先定位结果目录，避免启动后
    # 再让安装服务查询容器而超时，误把已启动的应用判成失败并重启设备。
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
        env['FLUXDO_SIMULATOR_UDID'], app_id, 'data'], text=True, timeout=75 if warmup else 15).strip()
    report_path = Path(container) / 'tmp' / report_name
    with subprocess.Popen(launch_command, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as launch:
        try:
            # 冷启动发生在网络测试前；单独给启动服务预算，不放宽正常网络导航时限。
            launch_stdout, launch_stderr = launch.communicate(timeout=75 if warmup else 25)
        except subprocess.TimeoutExpired:
            # 在终止前保存宿主启动命令调用栈，区分模拟器服务阻塞和应用执行失败。
            try:
                sample = subprocess.run(['sample', str(launch.pid), '1'],
                    capture_output=True, text=True, timeout=8)
                sys.stderr.write(sample.stdout + sample.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                sys.stderr.write('启动调用栈采集失败: ' + str(error) + '\n')
            finally:
                launch.kill()
                launch_stdout, launch_stderr = launch.communicate(timeout=5)
                sys.stderr.write(launch_stdout + launch_stderr)
            raise
    # 不附着可能阻塞的 simctl 控制台；退出结果由本次启动的独立文件核验。
    sys.stderr.write(launch_stdout)
    sys.stderr.write(launch_stderr)
    code = launch.returncode
    if code:
        raise RuntimeError('simctl launch failed: ' + str(code))
    while not report_path.exists() and time.monotonic() < deadline:
        time.sleep(0.25)
    if not report_path.exists():
        raise subprocess.TimeoutExpired(['native WKWebView report'], report_timeout)
    report = json.loads(report_path.read_text())
    expected_engine = 'iOS production Core FFI' if core_driver and not warmup else 'native WKWebView'
    if report.get('engine') != expected_engine or report.get('success') is not True:
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
                        app_id], timeout=15, capture_output=True)
    except subprocess.TimeoutExpired:
        pass
raise SystemExit(code)
