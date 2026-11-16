#!/usr/bin/env python3
"""一次有预算上限的 iOS 真机协议检查；必须有同源码的 iOS Core 运行证据。"""
import argparse
import base64
import http.client
import json
import os
from pathlib import Path
import re
import time
import uuid

from verify_public_trace import verify
from validate_core_baseline import valid_baseline


class APIError(RuntimeError):
    def __init__(self, status, code):
        super().__init__(f'HTTP {status}: {code}')
        self.code = code


class API:
    def __init__(self, host, auth):
        self.host, self.auth = host, auth

    def __call__(self, path, method='GET', body=None, timeout=15, content_type='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
        connection = http.client.HTTPSConnection(self.host, timeout=timeout)
        try:
            connection.request(method, path, body=data, headers={'Authorization': self.auth, 'Content-Type': content_type})
            response = connection.getresponse()
            content = response.read()
            if response.status >= 300:
                try:
                    code = json.loads(content).get('value', {}).get('error', 'request_failed')
                except (ValueError, AttributeError):
                    code = 'request_failed'
                # 不打印服务器原始正文；错误消息可能包含凭据或签名下载 URL。
                raise APIError(response.status, code)
            return json.loads(content) if content else {}
        finally:
            connection.close()


def check_plan(plan):
    if (plan.get('automate_plan') != 'Free' or plan.get('parallel_sessions_running') != 0
            or plan.get('queued_sessions') != 0 or not isinstance(plan.get('parallel_sessions_max_allowed'), int)
            or plan['parallel_sessions_max_allowed'] < 1):
        raise RuntimeError('A free idle account with device capacity is required; no session started')


def observe(hub, session, deadline):
    def remaining():
        left = deadline-time.monotonic()
        if left <= 0:
            raise TimeoutError('One-session observation budget exhausted; no retry')
        return min(8, left)
    while time.monotonic() < deadline:
        try:
            found = hub(f'/wd/hub/session/{session}/element', 'POST',
                        {'using': 'accessibility id', 'value': 'fluxdo-core-report'}, timeout=remaining())['value']
            element = found.get('element-6066-11e4-a52e-4f735466cecf') or found.get('ELEMENT')
            if not element or not re.fullmatch(r'[A-Za-z0-9-]+', element):
                raise RuntimeError('Missing report element id')
            value = hub(f'/wd/hub/session/{session}/element/{element}/attribute/value', timeout=remaining())['value']
            return json.loads(value)
        except APIError as error:
            if error.code != 'no such element':
                raise
        time.sleep(1)
    raise TimeoutError('One-session observation budget exhausted; no retry')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ipa', type=Path, required=True)
    prerequisite = parser.add_mutually_exclusive_group(required=True)
    prerequisite.add_argument('--simulator-result', type=Path)
    prerequisite.add_argument('--controlled-core-result', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ios-major', type=int, default=15)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'maximum_session_creations': 1, 'session_released': False,
              'remaining_free_minutes_verified': False, 'observation_budget_seconds': 120}
    session = None
    started = None
    try:
        if args.controlled_core_result:
            baseline = json.loads(args.controlled_core_result.read_text())
            if not valid_baseline(baseline):
                raise RuntimeError('Controlled iOS Core baseline invalid; no device started')
            report['prerequisite'] = baseline
        else:
            simulator = json.loads(args.simulator_result.read_text())
            if simulator.get('passed') is not True or not verify(simulator.get('driver', {}), False):
                raise RuntimeError('Simulator public-trace prerequisite failed; no device started')
        credentials = [os.environ.get(k) for k in ('BROWSERSTACK_USERNAME', 'BROWSERSTACK_ACCESS_KEY')]
        if not all(credentials):
            raise RuntimeError('Configured credentials missing; no device started')
        auth = 'Basic '+base64.b64encode(':'.join(credentials).encode()).decode()
        api, hub = API('api-cloud.browserstack.com', auth), API('hub-cloud.browserstack.com', auth)
        check_plan(api('/app-automate/plan.json'))
        devices = api('/app-automate/devices.json')
        choices = [d for d in devices if d.get('os', '').lower() == 'ios'
                   and str(d.get('os_version', '')).split('.')[0] == str(args.ios_major)]
        if not choices:
            raise RuntimeError('Requested iOS major unavailable; no fallback or session started')
        device = sorted(choices, key=lambda d: d['device'])[0]
        report['requested_device'] = {k: device[k] for k in ('device', 'os_version')}
        boundary = uuid.uuid4().hex
        upload = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="ios-core-trace.ipa"\r\n'
                  f'Content-Type: application/octet-stream\r\n\r\n').encode()+args.ipa.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
        uploaded = api('/app-automate/upload', 'POST', upload, timeout=120,
                       content_type='multipart/form-data; boundary='+boundary)
        check_plan(api('/app-automate/plan.json'))
        capabilities = {'platformName': 'iOS', 'appium:automationName': 'XCUITest',
            'appium:deviceName': device['device'], 'appium:platformVersion': device['os_version'],
            'appium:app': uploaded['app_url'], 'appium:newCommandTimeout': 30, 'appium:autoAcceptAlerts': True,
            'bstack:options': {'projectName': 'FluxDO', 'buildName': 'ios-core-'+os.environ.get('GITHUB_RUN_ID', 'local'),
                'sessionName': 'One bounded iOS Core protocol check', 'idleTimeout': 30,
                'networkLogs': False, 'debug': False, 'video': False}}
        started = time.monotonic()
        report['creation_requests_sent'] = 1
        response = hub('/wd/hub/session', 'POST', {'capabilities': {'alwaysMatch': capabilities}}, timeout=60)
        candidate = response.get('value', {}).get('sessionId') or response.get('sessionId')
        if not candidate or not re.fullmatch(r'[A-Za-z0-9-]+', candidate):
            raise RuntimeError('No session id returned; creation is not retried')
        session = candidate
        report['session_id'] = session
        driver = observe(hub, session, started+120)
        report['driver'] = driver
        report['passed'] = verify(driver, True)
    except Exception as error:
        report['error'] = str(error)
    finally:
        if session:
            try:
                hub(f'/wd/hub/session/{session}', 'DELETE', timeout=15)
                report['session_released'] = True
            except Exception as error:
                report['cleanup_error'] = str(error)
                report['passed'] = False
        if started is not None:
            report['local_session_window_seconds'] = round(time.monotonic()-started, 2)
            if session is None:
                report['creation_outcome'] = 'Unknown without session id; no retry; server idle timeout is 30 seconds'
        if session and report['session_released']:
            try:
                data = api(f'/app-automate/sessions/{session}.json')
                info = data.get('automation_session', data)
                report['platform_session'] = {k: info.get(k) for k in ('status', 'duration', 'device', 'os_version', 'browser_url')}
            except Exception as error:
                report['metadata_error'] = str(error)
        (args.output/'result.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
    return 0 if report['passed'] and report['session_released'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
