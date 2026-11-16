#!/usr/bin/env python3
"""准备同源码的模拟器公开协议验证包与真机 IPA；此脚本不启动云设备。"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

from run import output, run
from prepare_trusted import app_info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepared', type=Path, required=True)
    stages = parser.add_mutually_exclusive_group()
    stages.add_argument('--simulator-only', action='store_true')
    stages.add_argument('--device-only', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    prepared = args.prepared.resolve()
    prepared.mkdir(parents=True, exist_ok=True)
    # Cloudflare 提供的公开只读协议诊断页；不访问用户账户、不发送业务写入。
    trace = {'url': 'https://cloudflare-quic.com/cdn-cgi/trace'}
    simulator = prepared/'WKCoreTrace.app'
    if not args.device_only:
        shutil.copytree(prepared/'WKCoreProbe.app', simulator)
        (simulator/'trace-target.json').write_text(json.dumps(trace)+'\n')
        run(['codesign', '--force', '--sign', '-', simulator], timeout=30)
    if args.simulator_only:
        return
    source = Path(__file__).with_name('WKProbe.swift')
    run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-swift-version', '5', '-parse-as-library',
         '-D', 'FLUXDO_CORE_DIAGNOSTIC', '-sdk', output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']),
         '-target', 'arm64-apple-ios15.0', source, repo/'ios/Runner/BrowserIdentity.swift', source.with_name('IOSCoreProbe.swift')], timeout=90)
    target = 'aarch64-apple-ios'
    run(['rustup', 'target', 'add', target], timeout=120)
    run(['cargo', 'rustc', '--locked', '--manifest-path', repo/'core/net_core/Cargo.toml',
         '--lib', '--crate-type', 'staticlib', '--target', target], timeout=1200,
         env=dict(os.environ, IPHONEOS_DEPLOYMENT_TARGET='15.0'))
    app = prepared/'Payload/WKCoreProbe.app'
    app.mkdir(parents=True)
    info = dict(app_info(), CFBundleIdentifier='org.fluxdo.fingerprint.core')
    info['CFBundleSupportedPlatforms'] = ['iPhoneOS']
    info['DTPlatformName'] = 'iphoneos'
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    (app/'trace-target.json').write_text(json.dumps(trace)+'\n')
    source = Path(__file__).with_name('WKProbe.swift')
    run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-swift-version', '5', '-parse-as-library',
         '-D', 'FLUXDO_CORE_DIAGNOSTIC', '-sdk', output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']),
         '-target', 'arm64-apple-ios15.0', source, repo/'ios/Runner/BrowserIdentity.swift', source.with_name('IOSCoreProbe.swift'),
         repo/'core/net_core/target'/target/'debug/libfluxdo_net.a',
         '-framework', 'UIKit', '-framework', 'WebKit', '-framework', 'Security',
         '-framework', 'CFNetwork', '-framework', 'CoreFoundation', '-lc++', '-liconv', '-o', app/'WKProbe'], timeout=180)
    run(['codesign', '--force', '--sign', '-', app], timeout=30)
    with zipfile.ZipFile(prepared/'ios-core-trace.ipa', 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob('*')):
            if file.is_file():
                archive.write(file, str(file.relative_to(prepared)))
    print('Prepared diagnostic IPA; BrowserStack will re-sign it; no device started')


if __name__ == '__main__':
    main()
