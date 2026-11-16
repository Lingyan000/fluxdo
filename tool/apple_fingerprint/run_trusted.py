#!/usr/bin/env python3
"""复用已预热的 Apple 宿主；只运行应用 UA 和证书负对照，不并行启动节点。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[2]
    rows = []
    for target in json.loads((args.prepared/'targets.json').read_text()):
        folder = args.output/target['name']
        env = dict(os.environ, **target['env'])
        env.pop('FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST', None)
        env.pop('FLUXDO_APPLE_LAB_CA', None)
        row = {'target': target['name'], 'passed': False}
        try:
            with (args.output/(target['name']+'.log')).open('w') as log:
                process = subprocess.run([sys.executable, str(root/'tool/native_fingerprint/tailscale_h3.py'),
                    '--platform', target['platform'], '--driver', target['driver'], '--production', '--app-only',
                    '--output', str(folder)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=360)
            row['exit_code'] = process.returncode
            row['result'] = json.loads((folder/'result.json').read_text())
            row['passed'] = process.returncode == 0 and row['result']['passed']
        except Exception as error:
            row['error'] = str(error)
        rows.append(row)
        (args.output/'matrix.json').write_text(json.dumps(rows, indent=2)+'\n')
        # 即使产物上传失败，CI 主日志仍保留结果和失败阶段，不只留下退出码。
        print(json.dumps({'target': target['name'], 'passed': row['passed'],
              'exit_code': row.get('exit_code'), 'error': row.get('error') or row.get('result', {}).get('error')}), flush=True)
    return 0 if rows and all(r['passed'] for r in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
