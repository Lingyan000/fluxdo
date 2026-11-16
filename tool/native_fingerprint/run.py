#!/usr/bin/env python3
"""运行原生浏览器采样与宿主 Core 对照，保留两端平台身份。"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_fingerprint_capture import compare

parser = argparse.ArgumentParser()
parser.add_argument('--production-h3', action='store_true')
parser.add_argument('--driver', type=Path, help='显式指定原生诊断宿主')
parser.add_argument('--qpack-scenarios', action='store_true', help='基线通过后比较九种原生/Core 扩展请求')
parser.add_argument('--spki-control', action='store_true', help='额外运行 Windows 临时证书许可对照，不代表默认配置')
parser.add_argument('--root-trust-only', action='store_true', help='只运行一次性 CI 的根证书与 SPKI 组合对照')
parser.add_argument('--force-quic-control', action='store_true', help='仅一次性 runner，按探针 origin 与 SPKI 限定 QUIC 对照')
parser.add_argument('--platform', choices=['android', 'windows'], required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if (args.spki_control or args.root_trust_only) and (args.platform != 'windows' or not args.production_h3):
    parser.error('certificate controls require --platform windows --production-h3')
if args.force_quic_control and not args.production_h3:
    parser.error('--force-quic-control requires --production-h3')
if args.qpack_scenarios and not args.production_h3:
    parser.error('--qpack-scenarios requires --production-h3')
root = Path(__file__).resolve().parents[2]
binary = root / 'core/net_core/target/debug/examples' / ('fingerprint_probe.exe' if os.name == 'nt' else 'fingerprint_probe')
driver = root / ('tool/native_fingerprint/windows/bin/Release/net8.0-windows/Probe.exe' if args.platform == 'windows' else 'tool/native_fingerprint/android_driver.py')
if args.driver:
    driver = args.driver.resolve()
args.output.mkdir(parents=True, exist_ok=True)
matrix = []
for mode in ((['forced-native-spki-control', 'forced-app-spki-control'] if args.platform == 'android' else ['forced-spki-control']) if args.force_quic_control else ['root-spki-control'] if args.root_trust_only else ['native', 'app'] if args.platform == 'android' else
             ['native', 'spki-control', 'root-spki-control'] if args.spki_control else ['native']):
    folder = args.output / (args.platform + '-' + mode)
    folder.mkdir()
    env = dict(os.environ, FLUXDO_LAB_EXTERNAL_DRIVER='1', FLUXDO_ANDROID_UA_MODE='app' if 'app' in mode.split('-') else 'native',
               SSL_CERT_FILE=str(folder / 'ca.pem'), SSL_CERT_EXTRA_FILE=str(folder / 'ca.pem'))
    result = {'case': folder.name, 'browser_platform': args.platform, 'core_host': platform.platform(),
              'evidence_kind': 'native_minimal_host', 'full_flutter_app': False, 'driver': str(driver)}
    try:
        with (folder / 'run.log').open('w', encoding='utf-8') as log:
            process = subprocess.run([str(binary), str(driver), str(folder)], env=env,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=240)
        result['exit_code'] = process.returncode
        result['comparison'] = compare(folder)
        result['passed'] = process.returncode == 0 and result['comparison']['all_checked_fields_match']
        if args.production_h3 and result['passed']:
            production=folder/'production-h3'
            production.mkdir()
            suffix='.exe' if os.name=='nt' else ''
            examples=root/'core/net_core/target/debug/examples'
            h3env=dict(env, FLUXDO_ANDROID_H3_RELAY='1' if args.platform=='android' else '0', FLUXDO_H3_NATIVE_DRIVER='1', FLUXDO_H3_BROWSER=str(driver.resolve()),
                FLUXDO_H3_DIAGNOSTIC_SPKI='1' if mode.endswith('spki-control') else '0',
                FLUXDO_NATIVE_PROBE_TRUST_ROOT='1' if mode=='root-spki-control' else '0',
                FLUXDO_NATIVE_PROBE_FORCE_QUIC='1' if args.force_quic_control else '0',
                FLUXDO_TCP_SAMPLES=str(folder), FLUXDO_H3_OUTPUT=str(production/'client'),
                SSL_CERT_FILE=str(production/'server/h3-ca.pem'), SSL_CERT_EXTRA_FILE=str(production/'server/h3-ca.pem'))
            with (production/'run.log').open('w') as log:
                h3process=subprocess.run([str(examples/('h3_fingerprint_probe'+suffix)),str(examples/('h3_production_client'+suffix)),str(production/'server'),'--native-probe'],
                    env=h3env,stdout=log,stderr=subprocess.STDOUT,timeout=240)
            result['production_h3_exit_code']=h3process.returncode
            result['diagnostic_spki_override']=mode.endswith('spki-control')
            result['diagnostic_root_trust']=mode=='root-spki-control'
            result['diagnostic_force_quic']=args.force_quic_control
            result['passed'] &= h3process.returncode==0
            if (production/'client/profile.json').exists() and (production/'server/h3-capture.json').exists():
                from compare_h3_production import compare as compare_h3
                result['production_h3_comparison']=compare_h3(production)
                result['passed'] &= result['production_h3_comparison']['all_checked_fields_match']
            if args.qpack_scenarios and result['passed']:
                extended = folder / 'qpack-scenarios'
                with (folder / 'qpack-scenarios.log').open('w') as log:
                    process = subprocess.run([sys.executable, str(root/'tool/run_h3_qpack_scenarios.py'),
                        '--browser', str(driver.resolve()), '--samples', str(folder.resolve()),
                        '--output', str(extended.resolve()), '--native-driver'],
                        env=h3env, stdout=log, stderr=subprocess.STDOUT, timeout=540)
                result['qpack_comparison'] = json.loads((extended/'comparison.json').read_text())
                result['passed'] &= process.returncode == 0 and result['qpack_comparison']['passed']
    except Exception as error:
        result.update(passed=False, error=str(error))
    matrix.append(result)
    (args.output / 'matrix.json').write_text(json.dumps(matrix, indent=2) + '\n', encoding='utf-8')
    print(folder.name, 'PASS' if result['passed'] else 'FAIL', flush=True)
raise SystemExit(0 if all(r['passed'] for r in matrix) else 1)
