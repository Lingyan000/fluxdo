"""在云端 Mac 运行原生 WKWebView 与 iOS 模拟器；所有证据仅含回环测试流量。"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_fingerprint_capture import compare


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def output(command):
    return subprocess.check_output(command, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--h3', action='store_true', help='验证原生证书回调下的 Alt-Svc/H3 采样能力')
    parser.add_argument('--system-trust', action='store_true', help='只在一次性 CI 环境安装实验 CA，并要求系统校验')
    parser.add_argument('--simulator-limit', type=int, default=2)
    parser.add_argument('--include-oldest', action='store_true')
    parser.add_argument('--ios-version', help='仅重跑指定的已安装 iOS 运行时；省略时执行版本矩阵')
    args = parser.parse_args()
    if args.system_trust and (not args.h3 or os.environ.get('GITHUB_ACTIONS') != 'true'):
        parser.error('--system-trust requires --h3 on an ephemeral GitHub runner')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    source = Path(__file__).parent / 'WKProbe.swift'
    binary = repo / 'core/net_core/target/debug/examples' / ('h3_fingerprint_probe' if args.h3 else 'fingerprint_probe')
    metadata = {'uname': platform.uname()._asdict(), 'sw_vers': output(['sw_vers']),
                'xcode': output(['xcodebuild', '-version']), 'git': output(['git', 'rev-parse', 'HEAD']),
                'host': 'minimal native WKWebView, not the full Flutter application',
                'core_platform': 'macOS host for both macOS and iOS simulator samples'}
    (root / 'environment.json').write_text(json.dumps(metadata, indent=2))
    results = []

    def save():
        (root / 'matrix.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')

    def case(name, driver, extra_env, retry_startup=True):
        folder = root / name
        folder.mkdir()
        env = dict(os.environ, SSL_CERT_FILE=str(folder / 'ca.pem'),
                   SSL_CERT_EXTRA_FILE=str(folder / 'ca.pem'), FLUXDO_LAB_EXTERNAL_DRIVER='1', **extra_env)
        if args.system_trust:
            env.update(FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST='1', FLUXDO_APPLE_LAB_CA=str(folder / 'h3-ca.pem'))
        result = {'case': name, 'evidence_kind': 'native_wkwebview', 'configuration': extra_env}
        try:
            with (folder / 'run.log').open('w') as log:
                process = subprocess.run([str(binary), str(driver), str(folder)] + (['--native-probe'] if args.h3 else []), env=env,
                                         stdout=log, stderr=subprocess.STDOUT, timeout=240)
            result['exit_code'] = process.returncode
            native = []
            for path in sorted(folder.glob('browser*.stdout')):
                for line in path.read_text().splitlines():
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(value, dict) and value.get('engine') == 'native WKWebView':
                        native.append(value)
            result['native_runs'] = native
            if args.h3:
                result['h3_capture'] = json.loads((folder / 'h3-capture.json').read_text())
                # 实验完成不等于 H3 支持，更不等于指纹回放通过。
                result['h3_sample_complete'] = result['h3_capture']['h3_sample_complete']
                result['passed'] = process.returncode == 0 and len(native) == 1 and all(r['success'] for r in native)
            else:
                result['comparison'] = compare(folder)
                result['passed'] = process.returncode == 0 and len(native) == 2 and all(r['success'] for r in native) and result['comparison']['all_checked_fields_match']
        except (OSError, ValueError, KeyError, AssertionError, subprocess.TimeoutExpired) as error:
            result['error'] = str(error)
            result['passed'] = False
        # 仅重试 simctl 尚未启动宿主的冷启动超时；保留第一轮全部证据。
        # 页面报错、已采样的校准失败或指纹不匹配不重试，不用重试掩盖核心问题。
        startup = folder / 'browser-driver-0.json'
        if retry_startup and not result['passed'] and startup.exists() and not (folder / 'browser-sample-0.json').exists():
            state = json.loads(startup.read_text())
            stdout = folder / 'browser-0.stdout'
            if state.get('code') == 124 and (not stdout.exists() or not stdout.read_text().strip()):
                folder.rename(root / (name + '-startup-failed'))
                retried = case(name, driver, extra_env, retry_startup=False)
                retried['startup_failure'] = result
                save()
                return retried
        results.append(result)
        save()
        print(name, 'PASS' if result['passed'] else 'FAIL', flush=True)
        return result

    mac = root / 'WKProbe-macos'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', source, repo / 'ios/Runner/BrowserIdentity.swift',
         '-framework', 'AppKit', '-framework', 'WebKit', '-o', mac])
    for mode in ('native', 'app'):
        case('macos-' + mode, Path(__file__).parent / 'mac_driver.py' if args.system_trust else mac,
             {'FLUXDO_APPLE_UA_MODE': mode, 'FLUXDO_MAC_DRIVER_BINARY': str(mac)})

    simulator_data = json.loads(output(['xcrun', 'simctl', 'list', '--json']))
    (root / 'simulators.json').write_text(json.dumps(simulator_data, indent=2))
    runtimes = [r for r in simulator_data['runtimes'] if r.get('isAvailable') and r.get('name', '').startswith('iOS ')]
    if args.ios_version:
        runtimes = [r for r in runtimes if r['version'] == args.ios_version]
    runtimes.sort(key=lambda r: tuple(int(n) for n in r['version'].split('.')), reverse=True)
    if args.include_oldest and len(runtimes) > args.simulator_limit:
        runtimes = runtimes[:max(0, args.simulator_limit - 1)] + [runtimes[-1]]
    else:
        runtimes = runtimes[:args.simulator_limit]
    if not runtimes:
        results.append({'case': 'ios-runtime', 'passed': False, 'error': 'No available iOS simulator runtime'})
        save()
        return 1
    app = root / 'WKProbe.app'
    app.mkdir()
    info = {'CFBundleExecutable': 'WKProbe', 'CFBundleIdentifier': 'org.fluxdo.fingerprint.probe',
            'CFBundleName': 'WKProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.0', 'LSRequiresIPhoneOS': True,
            'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'UIDeviceFamily': [1, 2],
            'UILaunchScreen': {}, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True, 'NSAllowsArbitraryLoadsInWebContent': True}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    sdk = output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
         '-target', arch + '-apple-ios15.0-simulator', source, repo / 'ios/Runner/BrowserIdentity.swift', '-framework', 'UIKit', '-framework', 'WebKit', '-o', app / 'WKProbe'])
    run(['codesign', '--force', '--sign', '-', app])
    driver = Path(__file__).parent / 'ios_driver.py'
    for runtime in runtimes:
        devices = [d for d in simulator_data['devices'].get(runtime['identifier'], []) if d.get('isAvailable') and 'iPhone' in d['name']]
        udid = None
        try:
            compatible = [d for d in runtime.get('supportedDeviceTypes', []) if d.get('productFamily') == 'iPhone']
            if not devices and not compatible:
                raise RuntimeError('No compatible iPhone device type')
            device_type = devices[0]['deviceTypeIdentifier'] if devices else compatible[0]['identifier']
            udid = output(['xcrun', 'simctl', 'create', 'FluxDO-Fingerprint', device_type, runtime['identifier']])
            run(['xcrun', 'simctl', 'boot', udid])
            run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=240)
            run(['xcrun', 'simctl', 'install', udid, app])
            with (root / ('ios-' + runtime['version'] + '-warmup.stdout')).open('w') as stdout, \
                 (root / ('ios-' + runtime['version'] + '-warmup.stderr')).open('w') as stderr:
                run(['xcrun', 'simctl', 'launch', '--terminate-running-process', '--console',
                     udid, 'org.fluxdo.fingerprint.probe', '--warmup'],
                    stdout=stdout, stderr=stderr, timeout=120)
            warmup = (root / ('ios-' + runtime['version'] + '-warmup.stdout')).read_text()
            if not any(line.startswith('{') and json.loads(line).get('warmup') and
                       json.loads(line).get('success') for line in warmup.splitlines()):
                raise RuntimeError('WebContent initialization did not succeed; see warmup evidence')
            for mode in ('native', 'app'):
                case('ios-' + runtime['version'] + '-' + mode, driver,
                     {'FLUXDO_SIMULATOR_UDID': udid, 'FLUXDO_APPLE_UA_MODE': mode})
        except (RuntimeError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            results.append({'case': 'ios-' + runtime['version'], 'passed': False, 'error': str(error)})
            save()
        finally:
            if udid:
                subprocess.run(['xcrun', 'simctl', 'shutdown', udid])
                subprocess.run(['xcrun', 'simctl', 'delete', udid])
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
