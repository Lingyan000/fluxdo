#!/usr/bin/env python3
"""真机之前先用相同 iOS 宿主验证公开端点；不把协议确认称作线上指纹比对。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def verify(report, physical):
    native = report.get('native_public_trace', [])
    core = report.get('core_public_trace', [])
    return (report.get('success') is True and report.get('engine') == 'iOS production Core FFI'
            and report.get('physical_device') is physical and report.get('core_running_on_ios') is True
            and report.get('core_shutdown') is True
            and any(r.get('http', '').lower() in ('h3', 'http/3') for r in native)
            and bool(core) and core[-1].get('http_version') == '3.0'
            and core[-1].get('trace', {}).get('http', '').lower() in ('h3', 'http/3'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    targets = [t for t in json.loads((args.prepared/'targets.json').read_text()) if t.get('ios_core_installed')]
    if len(targets) != 1:
        raise RuntimeError('Exactly one prepared iOS Core target required')
    env = dict(os.environ, **targets[0]['env'], FLUXDO_APPLE_CORE_DRIVER='1', FLUXDO_APPLE_UA_MODE='app')
    for key in ('SSL_CERT_FILE', 'SSL_CERT_EXTRA_FILE', 'FLUXDO_TRUSTED_PROBE_HOST', 'FLUXDO_TRUSTED_PROBE_CONFIG',
                'FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST', 'FLUXDO_APPLE_LAB_CA'):
        env.pop(key, None)
    subprocess.run(['xcrun', 'simctl', 'install', env['FLUXDO_SIMULATOR_UDID'], str(args.prepared/'WKCoreTrace.app')], check=True, timeout=60)
    with (args.output/'browser.stdout').open('w') as out, (args.output/'browser.stderr').open('w') as error:
        completed = subprocess.run([sys.executable, str(Path(__file__).with_name('ios_driver.py')), 'https://cloudflare-quic.com/cdn-cgi/trace'],
                                   env=env, stdout=out, stderr=error, timeout=205)
    report = json.loads((args.output/'browser.stdout').read_text())
    passed = completed.returncode == 0 and verify(report, False)
    (args.output/'result.json').write_text(json.dumps({'passed': passed, 'driver': report}, indent=2)+'\n')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
