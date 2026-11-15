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
parser.add_argument('--platform', choices=['android', 'windows'], required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
binary = root / 'core/net_core/target/debug/examples' / ('fingerprint_probe.exe' if os.name == 'nt' else 'fingerprint_probe')
driver = root / ('tool/native_fingerprint/windows/bin/Release/net8.0-windows/Probe.exe' if args.platform == 'windows' else 'tool/native_fingerprint/android_driver.py')
args.output.mkdir(parents=True, exist_ok=True)
matrix = []
for mode in (['native', 'app'] if args.platform == 'android' else ['native']):
    folder = args.output / (args.platform + '-' + mode)
    folder.mkdir()
    env = dict(os.environ, FLUXDO_LAB_EXTERNAL_DRIVER='1', FLUXDO_ANDROID_UA_MODE=mode,
               SSL_CERT_FILE=str(folder / 'ca.pem'), SSL_CERT_EXTRA_FILE=str(folder / 'ca.pem'))
    result = {'case': folder.name, 'browser_platform': args.platform, 'core_host': platform.platform(),
              'evidence_kind': 'native_minimal_host', 'full_flutter_app': False}
    try:
        with (folder / 'run.log').open('w', encoding='utf-8') as log:
            process = subprocess.run([str(binary), str(driver), str(folder)], env=env,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=240)
        result['exit_code'] = process.returncode
        result['comparison'] = compare(folder)
        result['passed'] = process.returncode == 0 and result['comparison']['all_checked_fields_match']
    except Exception as error:
        result.update(passed=False, error=str(error))
    matrix.append(result)
    (args.output / 'matrix.json').write_text(json.dumps(matrix, indent=2) + '\n', encoding='utf-8')
    print(folder.name, 'PASS' if result['passed'] else 'FAIL', flush=True)
raise SystemExit(0 if all(r['passed'] for r in matrix) else 1)
