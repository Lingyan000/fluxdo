"""仅本地实验：比较浏览器与生产 Core 在多种真实请求形态下的 QPACK 表示。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from compare_h3_production import fields


CASES = {
    'conditional': ('GET', '', 'if_none_match', '"fluxdo-lab-etag"'),
    'form': ('POST', 'sample=one&value=two', 'content_type', 'application/x-www-form-urlencoded'),
    'json': ('POST', '{"sample":1}', 'content_type', 'application/json'),
    'range': ('GET', '', 'range', 'bytes=0-15'),
    'head': ('HEAD', '', None, None),
    'conditional-changed': ('GET', '', 'if_none_match', '"fluxdo-lab-etag-changed-20261115"'),
    'form-again': ('POST', 'sample=two&value=one', 'content_type', 'application/x-www-form-urlencoded'),
    'conditional-again': ('GET', '', 'if_none_match', '"fluxdo-lab-etag"'),
    'conditional-third': ('GET', '', 'if_none_match', '"fluxdo-lab-etag"'),
}


def compare_cases(native, core):
    def requests(capture):
        return {r['path'].rsplit('/', 1)[-1]: r for r in capture['h3'] if '/qpack/' in r['path']}
    source, actual = requests(native), requests(core)
    results = []
    for case, (method, body, key, value) in CASES.items():
        a, b = source.get(case), actual.get(case)
        checks = {'both_requests_present': a is not None and b is not None,
                  'exactly_once': all(sum(r['path'].endswith('/qpack/'+case) for r in capture['h3']) == 1
                                      for capture in (native,core))}
        differences = {}
        if a is not None and b is not None:
            checks.update(methods=a['method'] == b['method'] == method,
                          body_digest=a['body_sha256'] == b['body_sha256'] == hashlib.sha256(body.encode()).hexdigest(),
                          observed_field_complete=a['request']['fields_complete'] and b['request']['fields_complete'],
                          observed_field_shape=all(bool(r['request']['names']) and
                              len(r['request']['names']) == len(r['request']['fields']) for r in (a, b)),
                          same_stream_phase=a['request']['stream_id'] == b['request']['stream_id'],
                          accept_encoding_value=a.get('accept_encoding') is not None and a.get('accept_encoding') == b.get('accept_encoding'))
            if key:
                checks['business_header_preserved'] = a.get(key) == b.get(key) == value
            # 完整标记不能代替结构核验；空数组和长度错配必须明确失败。
            af = fields(a['request']['names'], a['request']['fields']) if checks['observed_field_shape'] else {}
            bf = fields(b['request']['names'], b['request']['fields']) if checks['observed_field_shape'] else {}
            differences = {name: {'native': af.get(name), 'core': rep}
                           for name, rep in bf.items() if af.get(name) != rep}
            checks['qpack_common_fields'] = checks['observed_field_shape'] and not differences
            source_only=sorted(set(af)-set(bf))
        results.append({'case': case, 'checks': checks, 'differences': differences, 'source_fields_not_requested':source_only if a is not None and b is not None else [], 'passed': all(checks.values())})
    def same_connection(capture):
        cases=[r for r in capture['h3'] if '/qpack/' in r['path']]
        return bool(cases) and len({r['flow_id'] for r in cases})==1
    checks = {'same_connection_each_side':same_connection(native) and same_connection(core),
              'native_complete': native.get('joint_capture_complete') is True,
              'core_complete': core.get('joint_capture_complete') is True,
              'native_driver_succeeded': not native.get('native_probe') or native.get('driver_success') is True,
              'core_driver_succeeded': core.get('driver_success') is True,
              'no_connection_errors': not native['connection_errors'] and not core['connection_errors'],
              'all_cases_match': all(r['passed'] for r in results)}
    return {'checks': checks, 'passed': all(checks.values()), 'cases': results,
            'scope': ('local native WebView with scoped QUIC/SPKI control' if native.get('native_probe_force_quic') else
                      'local native WebView Alt-Svc' if native.get('native_probe') else 'local forced QUIC browser fetch') + ' and production Core; synthetic values; common transmitted fields only',
            'not_verified': ['physical devices', 'arbitrary request purposes', 'Cloudflare acceptance']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--browser', required=True)
    parser.add_argument('--samples', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--native-driver', action='store_true', help='使用原生 WKWebView 宿主，通过 Alt-Svc 选择 H3')
    args = parser.parse_args()
    binaries = Path(__file__).resolve().parents[1] / 'core/net_core/target/debug/examples'
    suffix = '.exe' if os.name == 'nt' else ''
    args.output = args.output.resolve()
    driver_codes={}
    for mode in ('native', 'core'):
        folder = args.output / mode
        folder.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, FLUXDO_H3_OUTPUT=str(folder / 'client'),
                   FLUXDO_TCP_SAMPLES=str(args.samples.resolve()), FLUXDO_H3_BROWSER=args.browser,
                   FLUXDO_H3_NETWORK_SCENARIO='qpack',
                   SSL_CERT_FILE=str(folder / 'h3-ca.pem'), SSL_CERT_EXTRA_FILE=str(folder / 'h3-ca.pem'))
        if args.native_driver:
            env['FLUXDO_H3_NATIVE_DRIVER'] = '1'
            env.pop('FLUXDO_H3_FORCE_QUIC', None)
        else:
            env['FLUXDO_H3_FORCE_QUIC'] = '1'
            env.pop('FLUXDO_H3_NATIVE_DRIVER', None)
        command = [str(binaries / ('h3_fingerprint_probe' + suffix)), args.browser if mode == 'native' else
                   str(binaries / ('h3_production_client' + suffix)), str(folder)]
        command += ['--learn-alt-svc', '--qpack-scenarios'] if mode == 'native' else ['--native-probe']
        if mode == 'native' and args.native_driver:
            # 与生产校准探针一致：公告 Alt-Svc 后关闭旧 TCP 连接，允许原生栈重新选路。
            command += ['--native-probe', '--close-tcp']
        with (folder / 'run.log').open('w') as log:
            completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240 if args.native_driver else 120)
        driver_codes[mode]=completed.returncode
        if completed.returncode:
            print(f'{mode} driver failed: {folder / "run.log"}', flush=True)
    native, core = (json.loads((args.output / mode / 'h3-capture.json').read_text()) for mode in ('native', 'core'))
    result = compare_cases(native, core)
    result['driver_exit_codes']=driver_codes
    result['checks']['drivers_exited_zero']=all(code==0 for code in driver_codes.values())
    result['passed']=all(result['checks'].values())
    (args.output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
