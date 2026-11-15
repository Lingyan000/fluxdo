"""以真实采样配置验证生产 Core 的故障恢复；仅面向回环实验服务器。"""
import argparse
import json
import os
from pathlib import Path
import subprocess


def verify(folder, case, exit_code):
    capture = json.loads((folder / 'server/h3-capture.json').read_text())
    requests = json.loads((folder / 'client/core-requests.json').read_text())
    network = capture['network_scenario']
    h3 = capture['h3']
    writes = [r for r in h3 + capture['tcp_requests'] if r.get('method') == 'POST']
    checks = {
        'driver_succeeded': exit_code == 0 and capture['driver_success'] is True,
        'no_connection_error': not capture['connection_errors'],
        'single_post': len(writes) == 1 and writes[0]['path'] == '/fluxdo-probe/write',
        'last_request_recorded': any(r['path'] == '/fluxdo-probe/finished'
                                     for r in h3 + capture['tcp_requests']),
    }
    if case == 'blocked':
        checks.update(udp_was_blocked=network['dropped_datagrams'] > 0,
                      no_h3=not h3,
                      h2_fallback=all(r['version'] == 'HTTP/2.0' for r in requests))
    else:
        checks.update(h3_reached=any(r['version'] == 'HTTP/3.0' for r in requests),
                      post_body_intact=len(writes) == 1 and writes[0]['body_bytes'] == 12)
    if case == 'loss':
        checks['one_initial_dropped'] = network['dropped_datagrams'] == 1
    elif case == 'retry':
        checks['retry_received'] = network['issued_retries'] >= 1
    elif case == 'reset':
        rounds = [r for r in requests if r.get('round') is not None and r['version'] == 'HTTP/3.0']
        checks['both_rounds_h3'] = {r['round'] for r in rounds} == {0, 1}
        checks['fresh_connections'] = len({r['connection_id'] for r in rounds}) == 2
        checks['reset_does_not_resume_old_session'] = all(r['resumed'] is False for r in rounds)
        firsts = {}
        for request in h3:
            firsts.setdefault(request['flow_id'], request)
        checks['new_qpack_stream_zero'] = len(firsts) == 2 and all(
            r['request']['stream_id'] == 0 for r in firsts.values())
        grease = [tuple((s['id'], s['value']) for s in r['first_request_boundary']['snapshot']['settings']
                        if s['grease']) for r in firsts.values()]
        # 无 GREASE 的原生配置无需凭空补发；有 GREASE 时不能复制旧连接值。
        checks['fresh_grease_if_present'] = not any(grease) or len(set(grease)) == 2
    return {'case': case, 'checks': checks, 'passed': all(checks.values()),
            'scope': 'local production Core, sampled profile, synthetic network faults',
            'not_verified': ['physical device', 'cellular/WiFi migration', 'Cloudflare outcome',
                             'exact fingerprint equivalence during retransmission']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--browser', required=True)
    parser.add_argument('--samples', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--force-quic', action='store_true',
                        help='仅实验浏览器采样强制 QUIC，不能用作原生 WebView 可用性证据')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    binaries = root / 'core/net_core/target/debug/examples'
    suffix = '.exe' if os.name == 'nt' else ''
    results = []
    for case, flag in [('loss', '--drop-first-initial'), ('retry', '--require-retry'),
                       ('blocked', '--block-quic'), ('reset', None)]:
        folder = args.output.resolve() / case
        (folder / 'server').mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env.update(FLUXDO_H3_OUTPUT=str(folder / 'client'),
                   FLUXDO_TCP_SAMPLES=str(args.samples.resolve()),
                   FLUXDO_H3_BROWSER=args.browser, FLUXDO_H3_NETWORK_SCENARIO=case,
                   SSL_CERT_FILE=str(folder / 'server/h3-ca.pem'))
        env.pop('FLUXDO_H3_FORCE_QUIC', None)
        if args.force_quic:
            env['FLUXDO_H3_FORCE_QUIC'] = '1'
        command = [str(binaries / ('h3_fingerprint_probe' + suffix)),
                   str(binaries / ('h3_production_client' + suffix)),
                   str(folder / 'server'), '--native-probe'] + ([flag] if flag else [])
        with (folder / 'run.log').open('w') as log:
            try:
                completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                           timeout=120, check=False)
                result = verify(folder, case, completed.returncode)
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                result = {'case': case, 'passed': False, 'error': str(error)}
        (folder / 'scenario-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
        results.append(result)
        print(case, json.dumps(result), flush=True)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'matrix.json').write_text(json.dumps(results, indent=2) + '\n')
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
