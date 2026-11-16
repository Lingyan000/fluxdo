"""运行本地真实浏览器及预置模板矩阵，保留失败证据，不将模板回放算作真机。"""
import argparse
import json
import os
from pathlib import Path
import subprocess

from compare_fingerprint_capture import compare


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chromium', type=Path)
    parser.add_argument('--chromium99', type=Path)
    parser.add_argument('--chromium110', type=Path)
    parser.add_argument('--webkit-driver', type=Path)
    parser.add_argument('--fixtures', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    binary = repo / 'core/net_core/target/debug/examples/fingerprint_probe'
    cases = []
    for label, browser in [('chromium99', args.chromium99), ('chromium110', args.chromium110), ('chromium', args.chromium)]:
        if browser:
            cases.append((label, str(browser), [], False))
    if args.chromium110:
        cases.append(('chromium110-permuted', str(args.chromium110), ['--enable-features=PermuteTLSExtensions'], False))
    if args.chromium:
        cases.append(('chromium-custom-ua', str(args.chromium), ['--user-agent=FluxDO-Lab-CustomUA/1'], False))
    if args.webkit_driver:
        cases.append(('webkit', str(args.webkit_driver), [], True))
    if args.fixtures:
        for path in sorted((repo / 'core/net_core/presets').glob('*.json')):
            document = json.loads(path.read_text())
            if isinstance(document, dict) and 'hello' in document and 'early_frames' in document:
                cases.append(('fixture-' + path.stem, 'fixture:' + str(path), [], False))
    if not cases:
        parser.error('至少选择一种浏览器或模板矩阵')
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for name, browser, flags, external in cases:
        folder = args.output / name
        # 不复用先前的浏览器配置、TLS 缓存或结果。
        folder.mkdir()
        env = dict(os.environ, SSL_CERT_FILE=str(folder / 'ca.pem'), SSL_CERT_EXTRA_FILE=str(folder / 'ca.pem'))
        if external:
            env['FLUXDO_LAB_EXTERNAL_DRIVER'] = '1'
        command = [str(binary), browser, str(folder), *flags]
        result = {'case': name, 'evidence_kind': 'fixture_replay' if name.startswith('fixture-') else 'live_browser', 'command': command}
        with (folder / 'run.log').open('w') as log:
            try:
                process = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
                result['exit_code'] = process.returncode
            except subprocess.TimeoutExpired:
                result['error'] = 'timeout'
        try:
            result['comparison'] = compare(folder)
        except (OSError, ValueError, KeyError, AssertionError) as error:
            result['comparison_error'] = str(error)
        result['passed'] = result.get('exit_code') == 0 and result.get('comparison', {}).get('all_checked_fields_match', False)
        results.append(result)
        (args.output / 'matrix.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
        print(name, 'PASS' if result['passed'] else 'FAIL', flush=True)
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__':
    main()
