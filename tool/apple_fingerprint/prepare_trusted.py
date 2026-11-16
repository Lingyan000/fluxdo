#!/usr/bin/env python3
"""先构建并预热原生宿主，随后才加入短时测试网络；不修改系统证书库。"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess

from run import run, output, warmup_simulator


def app_info():
    return {'CFBundleExecutable': 'WKProbe', 'CFBundleIdentifier': 'org.fluxdo.fingerprint.probe',
            'CFBundleName': 'WKProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.0', 'LSRequiresIPhoneOS': True,
            'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'UIDeviceFamily': [1, 2],
            'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
            'UILaunchScreen': {}, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}


def cleanup(root):
    path = root/'devices.json'
    if not path.exists():
        return
    for udid in json.loads(path.read_text()):
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], timeout=30, check=False)
        subprocess.run(['xcrun', 'simctl', 'delete', udid], timeout=30, check=True)
    path.write_text('[]\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ios-version', default='26.2')
    parser.add_argument('--device-family', choices=('iPhone', 'iPad'), default='iPhone')
    parser.add_argument('--ios-only', action='store_true')
    parser.add_argument('--mac-only', action='store_true')
    parser.add_argument('--ios-core', action='store_true', help='另外构建并安装实际 iOS Core C ABI 宿主')
    parser.add_argument('--cleanup', action='store_true')
    args = parser.parse_args()
    if args.mac_only and (args.ios_only or args.ios_core):
        parser.error('--mac-only cannot be combined with iOS flags')
    root = args.output.resolve()
    if args.cleanup:
        cleanup(root)
        return
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    source = Path(__file__).with_name('WKProbe.swift')
    identity = repo/'ios/Runner/BrowserIdentity.swift'
    targets = []
    if not args.ios_only:
        binary = root/'WKProbe-macos'
        run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', source, identity,
             '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'Security', '-o', binary], timeout=120)
        targets.append({'name': 'macos', 'platform': 'macos', 'driver': str(binary), 'env': {}})
    if args.mac_only:
        (root/'targets.json').write_text(json.dumps(targets, indent=2)+'\n')
        return
    data = json.loads(output(['xcrun', 'simctl', 'list', '--json']))
    runtime = next((r for r in data['runtimes'] if r.get('isAvailable') and r.get('version') == args.ios_version
                    and r.get('name', '').startswith('iOS ')), None)
    if runtime is None:
        raise RuntimeError('Requested installed iOS runtime unavailable: '+args.ios_version)
    devices = [d for d in data['devices'].get(runtime['identifier'], [])
               if d.get('isAvailable') and args.device_family in d['name']]
    compatible = [d for d in runtime.get('supportedDeviceTypes', []) if d.get('productFamily') == args.device_family]
    if not devices and not compatible:
        raise RuntimeError('Requested iOS runtime has no compatible '+args.device_family+' device type')
    device_type = devices[0]['deviceTypeIdentifier'] if devices else compatible[0]['identifier']
    app = root/'WKProbe.app'
    app.mkdir(exist_ok=True)
    info = app_info()
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-parse-as-library',
         '-sdk', output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']),
         '-target', arch+'-apple-ios15.0-simulator', source, identity,
         '-framework', 'UIKit', '-framework', 'WebKit', '-framework', 'Security', '-o', app/'WKProbe'], timeout=180)
    run(['codesign', '--force', '--sign', '-', app], timeout=30)
    core_app = None
    if args.ios_core:
        core_app = root/'WKCoreProbe.app'
        core_app.mkdir(exist_ok=True)
        core_info = dict(info, CFBundleIdentifier='org.fluxdo.fingerprint.core')
        (core_app/'Info.plist').write_bytes(plistlib.dumps(core_info))
        target = 'aarch64-apple-ios-sim' if arch == 'arm64' else 'x86_64-apple-ios'
        # 先检查 Swift 宿主，再进行耗时的 Rust 交叉编译。
        run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-typecheck', '-swift-version', '5', '-parse-as-library',
             '-D', 'FLUXDO_CORE_DIAGNOSTIC', '-sdk', output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']),
             '-target', arch+'-apple-ios15.0-simulator', source, identity, source.with_name('IOSCoreProbe.swift')], timeout=90)
        run(['rustup', 'target', 'add', target], timeout=120)
        run(['cargo', 'rustc', '--locked', '--manifest-path', repo/'core/net_core/Cargo.toml',
             '--lib', '--crate-type', 'staticlib', '--target', target], timeout=1200,
             env=dict(os.environ, IPHONEOS_DEPLOYMENT_TARGET='15.0'))
        library = repo/'core/net_core/target'/target/'debug/libfluxdo_net.a'
        run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-parse-as-library',
             '-D', 'FLUXDO_CORE_DIAGNOSTIC', '-sdk', output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']),
             '-target', arch+'-apple-ios15.0-simulator', source, identity, source.with_name('IOSCoreProbe.swift'), library,
             '-framework', 'UIKit', '-framework', 'WebKit', '-framework', 'Security',
             '-framework', 'CFNetwork', '-framework', 'CoreFoundation', '-lc++', '-liconv',
             '-o', core_app/'WKProbe'], timeout=180)
        run(['codesign', '--force', '--sign', '-', core_app], timeout=30)
    udid = output(['xcrun', 'simctl', 'create', 'FluxDO-Trusted-H3', device_type, runtime['identifier']])
    (root/'devices.json').write_text(json.dumps([udid])+'\n')
    try:
        run(['xcrun', 'simctl', 'boot', udid], timeout=90)
        simulator = Path(output(['xcode-select', '-p']))/'Applications/Simulator.app'
        run(['open', '-a', simulator, '--args', '-CurrentDeviceUDID', udid], timeout=30)
        run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=240)
        # 新建模拟器首次安装会等待系统应用注册；独立于探针的网络超时。
        run(['xcrun', 'simctl', 'install', udid, app], timeout=180)
        warmup_simulator(root, runtime['version'], udid)
        if core_app:
            run(['xcrun', 'simctl', 'install', udid, core_app], timeout=180)
        targets.append({'name': 'ios-'+runtime['version'], 'platform': 'ios',
                        'driver': str(Path(__file__).with_name('ios_driver.py').resolve()),
                        'env': {'FLUXDO_SIMULATOR_UDID': udid}, 'ios_core_installed': bool(core_app)})
        (root/'targets.json').write_text(json.dumps(targets, indent=2)+'\n')
    except Exception as error:
        (root/'preparation-failure.json').write_text(json.dumps({'error': str(error), 'udid': udid,
            'network_test_started': False}, indent=2)+'\n')
        with (root/'preparation-device.log').open('w') as log:
            try:
                subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '2m', '--style', 'compact',
                    '--predicate', 'process == "installd" OR process == "WKProbe" OR eventMessage CONTAINS "org.fluxdo.fingerprint"'],
                    stdout=log, stderr=subprocess.STDOUT, timeout=20, check=False)
            except (OSError, subprocess.TimeoutExpired) as diagnostic_error:
                log.write('\n'+str(diagnostic_error)+'\n')
        try:
            cleanup(root)
        except Exception as cleanup_error:
            (root/'cleanup-failure.json').write_text(json.dumps({'error': str(cleanup_error)})+'\n')
        raise


if __name__ == '__main__':
    main()
