"""重算已有 iOS 受控抓包，并确认 Core 源码一致；不把它当作公网 H3 通过。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tool'), str(ROOT/'tool/native_fingerprint')]
from compare_h3_production import transport_checks
from run_h3_qpack_scenarios import compare_cases
from tailscale_h3 import audit


def valid_baseline(data):
    checks = data.get('checks', {})
    return (data.get('kind') == 'controlled_ios_core' and data.get('passed') is True
            and bool(re.fullmatch(r'[0-9a-f]{40}', data.get('baseline_core_tree', '')))
            and data['baseline_core_tree'] == data.get('current_core_tree')
            and bool(checks) and all(value is True for value in checks.values()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--run', type=int, required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.head):
        raise ValueError('Expected immutable baseline commit')
    tree = lambda ref: subprocess.check_output(['git', 'rev-parse', ref+':core/net_core'], text=True).strip()
    result = {'kind': 'controlled_ios_core', 'passed': False, 'baseline_run': args.run,
              'baseline_head': args.head, 'baseline_core_tree': tree(args.head), 'current_core_tree': tree('HEAD'),
              'simulator_public_h3_verified': False, 'scope': 'Independent physical-network observation after controlled iOS Core verification'}
    if result['baseline_core_tree'] != result['current_core_tree']:
        raise RuntimeError('Core source differs from the verified baseline')
    paths = list(args.evidence.rglob('core-in-ios/result.json'))
    if len(paths) != 1:
        raise RuntimeError('Expected exactly one iOS Core capture')
    folder = paths[0].parent
    root = folder.parent
    baseline = json.loads(paths[0].read_text())
    driver = json.loads((folder/'capture/browser.stdout').read_text())
    native = json.loads((root/'app/h3-capture.json').read_text())
    captured = json.loads((folder/'capture/h3-capture.json').read_text())
    checks, _ = transport_checks(json.loads((folder/'profile.json').read_text()), captured)
    domain = json.loads((root/'result.json').read_text())['hostname']
    checks.update(baseline_passed=baseline.get('passed') is True,
        ios_core_ran=driver.get('core_running_on_ios') is True and driver.get('physical_device') is False,
        ios_core_succeeded=driver.get('success') is True and driver.get('engine') == 'iOS production Core FFI',
        core_stopped=driver.get('core_shutdown') is True,
        qpack_cases=compare_cases(native, captured)['passed'],
        trusted_certificate=audit(root/'app', domain)['passed'],
        untrusted_certificate=audit(root/'untrusted', domain, True)['passed'])
    result.update(checks=checks, passed=all(checks.values()), os=driver.get('os'))
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    return 0 if valid_baseline(result) else 1


if __name__ == '__main__':
    raise SystemExit(main())
