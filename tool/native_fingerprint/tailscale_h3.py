#!/usr/bin/env python3
"""单个短时 runner 上验证 Android 正常证书信任与 Alt-Svc H3；不代替产品回放。"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

from tailscale_preflight import node_identity, socket_checks, issue_certificate
from summarize_h3_netlog import read_netlog

CASES = {'conditional', 'form', 'json', 'range', 'head', 'conditional-changed',
         'form-again', 'conditional-again', 'conditional-third'}


def audit_browser(driver_path, netlog_path, hostname, negative=False):
    driver = json.loads(driver_path.read_text().strip())
    if driver.get('engine') == 'native WKWebView':
        evaluations = driver.get('system_trust_evaluations', [])
        strict = (driver.get('trusted_certificate_required') is True
                  and driver.get('ssl_errors_proceeded') == 0 and driver.get('diagnostic_force_quic') is False
                  and driver.get('udp_relay') is False and bool(evaluations)
                  and all(e.get('hostname') == hostname for e in evaluations))
        if negative:
            passed = (strict and driver.get('success') is False and driver.get('certificate_rejected') is True
                      and driver.get('ssl_error_count', 0) > 0
                      and any(e.get('system_trusted') is False for e in evaluations))
        else:
            passed = (strict and driver.get('success') is True and driver.get('ssl_error_count') == 0
                      and all(e.get('system_trusted') is True for e in evaluations))
        return {'passed': passed, 'negative': negative, 'driver': driver,
                'verification_backend': 'Security.framework default system trust',
                'certificate_results': evaluations, 'netlog_completeness': None,
                'command_line_check': 'Chromium flags not applicable to WKWebView'}
    data, completeness = read_netlog(netlog_path.read_text())
    names = {v: k for k, v in data['constants']['logEventTypes'].items()}
    ids = {e['source']['id'] for e in data['events']
           if names[e['type']] == 'CERT_VERIFIER_JOB' and e.get('params', {}).get('host') == hostname}
    certs = [e['params'] for e in data['events'] if e['source']['id'] in ids
             and names[e['type']] == 'CERT_VERIFIER_JOB' and 'cert_status' in e.get('params', {})]
    flags = [line for line in driver_path.with_suffix('.stderr').read_text().splitlines()
             if 'COMMAND-LINE FLAGS' in line]
    windows = driver.get('engine') == 'Flutter WebView2 production probe environment'
    if windows:
        command_line = data['constants'].get('clientInfo', {}).get('command_line', '')
        flags = [command_line] if command_line else []
    clean_flags = bool(flags) and all('--log-net-log=' in line and not any(flag in line for flag in
        ('--origin-to-force-quic-on', '--ignore-certificate-errors', '--host-resolver-rules')) for line in flags)
    strict = (driver.get('trusted_certificate_required') is True
              and driver.get('ssl_errors_proceeded') == 0
              and driver.get('udp_relay') is False
              and driver.get('diagnostic_force_quic') is False)
    if windows:
        strict &= (driver.get('environment_kind') == 'shared_main' and driver.get('main_survived') is True
                   and driver.get('main_profile_removed') is True and driver.get('isolated_h3_environment') is False)
    if negative:
        passed = (strict and clean_flags and driver.get('success') is False
                  and driver.get('ssl_error_count', 0) > 0
                  and (driver.get('certificate_rejected') is True if windows else str(driver.get('error', '')).startswith('certificate '))
                  and any(c.get('cert_status', 0) != 0 for c in certs))
    else:
        passed = (strict and clean_flags and driver.get('success') is True
                  and driver.get('ssl_error_count') == 0 and bool(certs)
                  and all(c.get('cert_status') == 0 and c.get('is_issued_by_known_root') is True
                          and c.get('net_error', 0) == 0 for c in certs))
    return {'passed': passed, 'negative': negative, 'driver': driver, 'clean_command_line': clean_flags,
            'certificate_results': [{k: c.get(k) for k in ('cert_status', 'is_issued_by_known_root', 'net_error')}
                                    for c in certs], 'netlog_completeness': completeness}


def audit(folder, hostname, negative=False):
    capture = json.loads((folder/'h3-capture.json').read_text())
    row = audit_browser(folder/'browser.stdout', folder/'browser-netlog.json', hostname, negative)
    row['passed'] &= capture.get('trusted_origin') is True and capture.get('spki_override') is False
    if negative:
        row['passed'] &= not capture['h3'] and not capture['tcp_requests']
    else:
        observed = {r['path'].removeprefix('/fluxdo-probe/qpack/') for r in capture['h3']
                    if r['path'].startswith('/fluxdo-probe/qpack/')}
        row['passed'] &= capture['joint_capture_complete'] is True and CASES <= observed
    row.update(h3_requests=len(capture['h3']), joint_capture_complete=capture['joint_capture_complete'],
               capture_sha256=hashlib.sha256((folder/'h3-capture.json').read_bytes()).hexdigest())
    return row


def production_replay(root, output, native, domain, env, driver=None):
    """正式 Listener 状态机采两次 H3，实际 HttpEgressClient 发九种合成请求。"""
    sys.path.insert(0, str(root/'tool'))
    from compare_fingerprint_capture import compare
    from run_h3_qpack_scenarios import compare_cases
    from compare_h3_production import transport_checks
    examples = root/'core/net_core/target/debug/examples'
    driver = driver or root/'tool/native_fingerprint/android_driver.py'
    suffix = '.exe' if os.name == 'nt' else ''
    samples = output/'tcp-samples'
    samples.mkdir()
    tcp_env = dict(env, FLUXDO_LAB_EXTERNAL_DRIVER='1', SSL_CERT_FILE=str(samples/'ca.pem'),
                   SSL_CERT_EXTRA_FILE=str(samples/'ca.pem'))
    for key in ('FLUXDO_TRUSTED_PROBE_CONFIG', 'FLUXDO_TRUSTED_PROBE_HOST'):
        tcp_env.pop(key, None)
    with (output/'tcp.log').open('w') as log:
        tcp = subprocess.run([str(examples/('fingerprint_probe'+suffix)), str(driver), str(samples)], env=tcp_env,
                             stdout=log, stderr=subprocess.STDOUT, timeout=90)
    tcp_comparison = compare(samples)
    result = {'tcp_exit_code': tcp.returncode, 'tcp_comparison': tcp_comparison, 'passed': False}
    if tcp.returncode != 0 or not tcp_comparison['all_checked_fields_match']:
        return result
    core = output/'core'
    replay_env = dict(env, FLUXDO_H3_NATIVE_DRIVER='1', FLUXDO_H3_BROWSER=str(driver),
                      FLUXDO_TCP_SAMPLES=str(samples), FLUXDO_H3_OUTPUT=str(core/'client'),
                      FLUXDO_H3_NETWORK_SCENARIO='qpack')
    for key in ('SSL_CERT_FILE', 'SSL_CERT_EXTRA_FILE', 'FLUXDO_H3_FORCE_QUIC',
                'FLUXDO_H3_DIAGNOSTIC_SPKI', 'FLUXDO_NATIVE_PROBE_TRUST_ROOT'):
        replay_env.pop(key, None)
    with (output/'replay.log').open('w') as log:
        replay = subprocess.run([str(examples/('h3_fingerprint_probe'+suffix)), str(examples/('h3_production_client'+suffix)),
                                 str(core), '--native-probe'], env=replay_env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=120)
    result['replay_exit_code'] = replay.returncode
    result['calibration_browsers'] = [audit_browser(core/'client'/f'browser-{i}.stdout',
        core/'client'/f'browser-netlog-{i}.json', domain) for i in range(2)]
    capture = json.loads((core/'h3-capture.json').read_text())
    checks, layout = transport_checks(json.loads((core/'client/profile.json').read_text()), capture)
    result['transport_comparison'] = {'passed': all(checks.values()), 'checks': checks, 'initial_layout': layout}
    result['comparison'] = compare_cases(json.loads((native/'h3-capture.json').read_text()), capture)
    result['comparison']['scope'] = 'trusted tailnet origin; native browser vs production Core; common fields; see driver platform identity'
    result['passed'] = (replay.returncode == 0 and result['comparison']['passed']
                        and result['transport_comparison']['passed']
                        and all(row['passed'] for row in result['calibration_browsers']))
    (output/'comparison.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--platform', choices=['android', 'windows', 'macos', 'ios'], default='android')
    parser.add_argument('--driver', type=Path)
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--app-only', action='store_true', help='保留原生 UA 已有证据，仅补应用 UA 与负对照')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.platform != 'android' and not args.driver:
        parser.error('--driver is required for this platform')
    driver = args.driver.resolve() if args.driver else root/'tool/native_fingerprint/android_driver.py'
    suffix = '.exe' if os.name == 'nt' else ''
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'scope': 'Android emulator to its Linux runner through emulator NAT' if args.platform == 'android' else 'native diagnostic host and Core on the same runner; iOS uses a simulator with Core on macOS',
              'platform': args.platform, 'core_host_platform': sys.platform,
              'native_reference_close_tcp': args.platform in ('macos', 'ios'),
              'browserstack_sessions': 0, 'rows': [],
              'production_requested': args.production, 'app_only': args.app_only,
              'not_verified': ['full Flutter production environment', 'cross-node tailnet path',
                               'physical devices', 'public Internet direct path', 'Cloudflare acceptance']}
    if args.platform == 'ios':
        report['not_verified'].append('Core running inside the iOS app; replay runs on the macOS host')
    try:
        domain, address = node_identity(json.loads(subprocess.check_output(['tailscale', 'status', '--json'], timeout=20)))
        report.update(hostname=domain, address=address)
        with tempfile.TemporaryDirectory(prefix='fluxdo-trusted-h3-') as temporary:
            folder = Path(temporary)
            cert, key = issue_certificate(folder, domain)
            report['preflight'] = socket_checks(cert, key, domain, address)
            bad_cert, bad_key = folder/'bad-cert.pem', folder/'bad-key.pem'
            openssl = shutil.which('openssl')
            if openssl is None and os.name == 'nt':
                openssl = str(Path(shutil.which('git')).parent.parent/'usr/bin/openssl.exe')
            if not openssl:
                raise RuntimeError('openssl executable missing')
            openssl_config = folder/'negative-cert.conf'
            openssl_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\nsubjectAltName=DNS:'+domain+'\n')
            subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', f'/CN={domain}', '-config', str(openssl_config),
                            '-keyout', str(bad_key), '-out', str(bad_cert)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            bad_key.chmod(0o600)
            modes = ('native', 'untrusted') if args.platform == 'windows' else (('app', 'untrusted') if args.app_only else ('native', 'app', 'untrusted'))
            for mode in modes:
                output = args.output/mode
                config = folder/'origin.json'
                negative = mode == 'untrusted'
                config.write_text(json.dumps({'hostname': domain, 'address': address,
                    'certificate': str(bad_cert if negative else cert),
                    'private_key': str(bad_key if negative else key)}))
                env = dict(os.environ, FLUXDO_TRUSTED_PROBE_CONFIG=str(config),
                           FLUXDO_NATIVE_PROBE_NETLOG='1', FLUXDO_NATIVE_PROBE_FORCE_QUIC='0',
                           FLUXDO_ANDROID_H3_RELAY='0', FLUXDO_ANDROID_UA_MODE='app' if mode == 'app' else 'native',
                           FLUXDO_APPLE_UA_MODE='app' if mode == 'app' else 'native')
                with (args.output/f'{mode}.log').open('w') as log:
                    result = subprocess.run([str(root/'core/net_core/target/debug/examples'/('h3_fingerprint_probe'+suffix)),
                        str(driver), str(output),
                        '--native-probe', '--qpack-scenarios'] + (['--close-tcp'] if args.platform in ('macos', 'ios') else []), env=env, stdout=log, stderr=subprocess.STDOUT, timeout=65)
                row = audit(output, domain, negative)
                row.update(case=mode, exit_code=result.returncode)
                row['passed'] &= result.returncode != 0 if negative else result.returncode == 0
                if args.production and not negative and row['passed']:
                    replay_output = args.output/(mode+'-replay')
                    replay_output.mkdir()
                    row['production'] = production_replay(root, replay_output, output, domain, env, driver)
                    row['passed'] &= row['production']['passed']
                report['rows'].append(row)
                (args.output/'result.json').write_text(json.dumps(report, indent=2)+'\n')
            report['passed'] = all(row['passed'] for row in report['rows'])
    except Exception as error:
        report['error'] = str(error)
    finally:
        (args.output/'result.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
