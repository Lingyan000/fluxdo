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
    parser.add_argument('--simulator-limit', type=int, default=2)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    source = Path(__file__).parent / 'WKProbe.swift'
    binary = repo / 'core/net_core/target/debug/examples/fingerprint_probe'
    metadata = {'uname': platform.uname()._asdict(), 'sw_vers': output(['sw_vers']),
                'xcode': output(['xcodebuild', '-version']), 'git': output(['git', 'rev-parse', 'HEAD']),
                'host': 'minimal native WKWebView, not the full Flutter application',
                'core_platform': 'macOS host for both macOS and iOS simulator samples'}
    (root / 'environment.json').write_text(json.dumps(metadata, indent=2))
    results = []

    def save():
        (root / 'matrix.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')

    def case(name, driver, extra_env):
        folder = root / name
        folder.mkdir()
        env = dict(os.environ, SSL_CERT_FILE=str(folder / 'ca.pem'),
                   SSL_CERT_EXTRA_FILE=str(folder / 'ca.pem'), FLUXDO_LAB_EXTERNAL_DRIVER='1', **extra_env)
        result = {'case': name, 'evidence_kind': 'native_wkwebview', 'configuration': extra_env}
        try:
            with (folder / 'run.log').open('w') as log:
                process = subprocess.run([str(binary), str(driver), str(folder)], env=env,
                                         stdout=log, stderr=subprocess.STDOUT, timeout=100)
            result['exit_code'] = process.returncode
            native = []
            for path in sorted(folder.glob('browser-*.stdout')):
                for line in path.read_text().splitlines():
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(value, dict) and value.get('engine') == 'native WKWebView':
                        native.append(value)
            result['native_runs'] = native
            result['comparison'] = compare(folder)
            result['passed'] = process.returncode == 0 and len(native) == 2 and all(r['success'] for r in native) and result['comparison']['all_checked_fields_match']
        except (OSError, ValueError, KeyError, AssertionError, subprocess.TimeoutExpired) as error:
            result['error'] = str(error)
            result['passed'] = False
        results.append(result)
        save()
        print(name, 'PASS' if result['passed'] else 'FAIL', flush=True)

    mac = root / 'WKProbe-macos'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', source,
         '-framework', 'AppKit', '-framework', 'WebKit', '-o', mac])
    for mode in ('native', 'app'):
        case('macos-' + mode, mac, {'FLUXDO_APPLE_UA_MODE': mode})

    simulator_data = json.loads(output(['xcrun', 'simctl', 'list', '--json']))
    (root / 'simulators.json').write_text(json.dumps(simulator_data, indent=2))
    runtimes = [r for r in simulator_data['runtimes'] if r.get('isAvailable') and r.get('name', '').startswith('iOS ')]
    runtimes.sort(key=lambda r: tuple(int(n) for n in r['version'].split('.')), reverse=True)
    runtimes = runtimes[:args.simulator_limit]
    if not runtimes:
        results.append({'case': 'ios-runtime', 'passed': False, 'error': 'No available iOS simulator runtime'})
        save()
        return 1
    app = root / 'WKProbe.app'
    app.mkdir()
    info = {'CFBundleExecutable': 'WKProbe', 'CFBundleIdentifier': 'org.fluxdo.fingerprint.probe',
            'CFBundleName': 'WKProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0', 'LSRequiresIPhoneOS': True,
            'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'UIDeviceFamily': [1, 2],
            'UILaunchScreen': {}, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True, 'NSAllowsArbitraryLoadsInWebContent': True}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    sdk = output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
         '-target', arch + '-apple-ios17.0-simulator', source, '-framework', 'UIKit', '-framework', 'WebKit', '-o', app / 'WKProbe'])
    run(['codesign', '--force', '--sign', '-', app])
    driver = Path(__file__).parent / 'ios_driver.py'
    for runtime in runtimes:
        devices = [d for d in simulator_data['devices'].get(runtime['identifier'], []) if d.get('isAvailable') and 'iPhone' in d['name']]
        udid = None
        try:
            if not devices:
                raise RuntimeError('No compatible iPhone device type')
            device_type = devices[0]['deviceTypeIdentifier']
            udid = output(['xcrun', 'simctl', 'create', 'FluxDO-Fingerprint', device_type, runtime['identifier']])
            run(['xcrun', 'simctl', 'boot', udid])
            run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=240)
            run(['xcrun', 'simctl', 'install', udid, app])
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
