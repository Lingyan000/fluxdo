#!/usr/bin/env python3
"""复核同一 iOS 模拟器中生产 C ABI 的 H3 请求；不把 macOS 回放算作 iOS Core。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tool'), str(ROOT/'tool/native_fingerprint')]
from compare_h3_production import transport_checks
from run_h3_qpack_scenarios import compare_cases
from tailscale_preflight import node_identity, issue_certificate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    targets = [t for t in json.loads((args.prepared/'targets.json').read_text()) if t.get('ios_core_installed')]
    if len(targets) != 1:
        raise RuntimeError('Exactly one prepared iOS Core target required')
    target = targets[0]
    folder = args.output/target['name']
    out = folder/'core-in-ios'
    out.mkdir(parents=True, exist_ok=True)
    result = {'passed': False, 'core_platform': 'ios-simulator', 'physical_device': False,
              'full_flutter_app': False, 'browserstack_sessions': 0}
    try:
        # 只有原生基准和宿主回放成功才追加设备内 Core，避免对无效证据做比较。
        previous = json.loads((folder/'result.json').read_text())
        if not previous['passed']:
            raise RuntimeError('Native trusted-origin reference failed')
        native = json.loads((folder/'app/h3-capture.json').read_text())
        domain, address = node_identity(json.loads(subprocess.check_output(['tailscale', 'status', '--json'], timeout=20)))
        with tempfile.TemporaryDirectory(prefix='fluxdo-ios-core-') as temp:
            config = Path(temp)/'origin.json'
            cert, key = issue_certificate(Path(temp), domain)
            config.write_text(json.dumps({'hostname': domain, 'address': address,
                                         'certificate': str(cert), 'private_key': str(key)}))
            env = dict(os.environ, **target['env'], FLUXDO_APPLE_CORE_DRIVER='1',
                       FLUXDO_TRUSTED_PROBE_CONFIG=str(config))
            # 与真机一致：应用内宿主必须自行传入 UA，不能靠 CI 环境变量补齐。
            env.pop('FLUXDO_APPLE_UA_MODE', None)
            for name in ('SSL_CERT_FILE', 'SSL_CERT_EXTRA_FILE', 'FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST',
                         'FLUXDO_APPLE_LAB_CA', 'FLUXDO_NATIVE_PROBE_SPKI', 'FLUXDO_NATIVE_PROBE_FORCE_QUIC'):
                env.pop(name, None)
            with (out/'run.log').open('w') as log:
                process = subprocess.run([str(ROOT/'core/net_core/target/debug/examples/h3_fingerprint_probe'),
                    target['driver'], str(out/'capture'), '--native-probe', '--qpack-scenarios'],
                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=205)
            driver = json.loads((out/'capture/browser.stdout').read_text())
            # 随机字段和连接初始状态必须与当前实例的采样比较，不能复用另一轮模板。
            profile = driver['calibrated_profile']
            (out/'profile.json').write_text(json.dumps(profile, indent=2)+'\n')
            capture = json.loads((out/'capture/h3-capture.json').read_text())
            comparisons = compare_cases(native, capture)
            checks, layout = transport_checks(profile, capture)
            result.update(exit_code=process.returncode, driver=driver, comparison=comparisons,
                          transport_checks=checks, initial_layout=layout)
            result['passed'] = (process.returncode == 0 and driver.get('success') is True
                and driver.get('engine') == 'iOS production Core FFI' and driver.get('core_running_on_ios') is True
                and driver.get('core_shutdown') is True and comparisons['passed'] and all(checks.values()))
    except Exception as error:
        result['error'] = str(error)
    finally:
        (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
