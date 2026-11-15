"""一次 Android 安装启动验证；无并发、无建连重试，始终主动释放设备。"""
import base64
import http.client
import json
import os
from pathlib import Path
import re
import time
import uuid

APP_URL = 'https://github.com/Lingyan000/fluxdo/releases/download/v0.2.30/fluxdo-arm64-v8a.apk'
PACKAGE = 'com.github.lingyan000.fluxdo'


class Client:
    def __init__(self, host, username, key):
        self.host = host
        self.authorization = 'Basic ' + base64.b64encode(f'{username}:{key}'.encode()).decode()
        self.credentials = (username, key)

    def __call__(self, path, method='GET', body=None, timeout=20, content_type='application/json'):
        headers = {'Authorization': self.authorization, 'Content-Type': content_type}
        data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
        connection = http.client.HTTPSConnection(self.host, timeout=timeout)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            raw = response.read()
            if response.status >= 300:
                detail = raw.decode(errors='replace')
                for credential in self.credentials:
                    detail = detail.replace(credential, '[redacted]')
                raise RuntimeError(f'{method} {path}: HTTP {response.status}: {detail[:800]}')
            return json.loads(raw) if raw else {}
        finally:
            connection.close()


def verify_plan(plan):
    # 本次只允许已确认的免费套餐；不以并发额度冒充剩余免费分钟。
    if plan.get('automate_plan') != 'Free':
        raise RuntimeError('Account is not the confirmed Free plan; no device started')
    if plan.get('parallel_sessions_running') != 0 or plan.get('queued_sessions') != 0:
        raise RuntimeError('Other sessions are running or queued; no device started')
    if not isinstance(plan.get('parallel_sessions_max_allowed'), int) or plan['parallel_sessions_max_allowed'] < 1:
        raise RuntimeError('No available device allowance; no device started')


def capture(api, hub, out, app_url, device, report):
    capabilities = {
        'platformName': 'Android',
        'appium:automationName': 'UiAutomator2',
        'appium:deviceName': device['device'],
        'appium:platformVersion': device['os_version'],
        'appium:app': app_url,
        'appium:autoGrantPermissions': True,
        'appium:appWaitDuration': 20000,
        'appium:newCommandTimeout': 30,
        'bstack:options': {
            'projectName': 'FluxDO',
            'buildName': 'fluxdo-budget-smoke-' + os.environ.get('GITHUB_RUN_ID', 'local'),
            'sessionName': 'Single Android launch check',
            'appiumVersion': '2.19.0',
            'idleTimeout': 30,
            'networkLogs': False,
            'debug': False,
            'video': True,
        },
    }
    session_id = None
    started = time.monotonic()
    try:
        # 创建请求只发送一次。创建超时也不重试，以免遗留第二个计时会话。
        response = hub('/wd/hub/session', 'POST', {'capabilities': {'alwaysMatch': capabilities}}, timeout=60)
        candidate = response.get('value', {}).get('sessionId') or response.get('sessionId')
        if not candidate or not re.fullmatch(r'[a-zA-Z0-9-]+', candidate):
            raise RuntimeError('No valid session id returned; no retry')
        session_id = candidate
        report['session_id'] = session_id
        report['session_created'] = True

        def command(suffix):
            remaining = 60 - (time.monotonic() - started)
            if remaining <= 0:
                raise TimeoutError('Local 60-second observation budget reached')
            return hub(f'/wd/hub/session/{session_id}/{suffix}', timeout=min(8, remaining)).get('value')

        package = command('appium/device/current_package')
        report['foreground_package'] = package
        screenshot = command('screenshot')
        (out / 'launch.png').write_bytes(base64.b64decode(screenshot, validate=True))
        source = command('source')
        (out / 'launch.xml').write_text(source)
        report['passed'] = package == PACKAGE
        if not report['passed']:
            raise RuntimeError('FluxDO was not the foreground package')
    finally:
        if session_id:
            try:
                hub(f'/wd/hub/session/{session_id}', 'DELETE', timeout=15)
                report['session_released'] = True
            finally:
                report['local_elapsed_seconds'] = round(time.monotonic() - started, 2)
        else:
            report['local_elapsed_seconds'] = round(time.monotonic() - started, 2)
            report['creation_outcome'] = 'No session id; creation was not retried; server idle timeout is 30 seconds'


def main():
    out = Path(os.environ.get('BROWSERSTACK_OUTPUT', 'browserstack-smoke-output'))
    out.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'session_created': False, 'session_released': False,
              'scope': 'FluxDO v0.2.30 Android install and launch only; not H3/CF validation',
              'maximum_session_creations': 1, 'remaining_free_minutes': 'not exposed by plan API'}
    try:
        username = os.environ['BROWSERSTACK_USERNAME']
        key = os.environ['BROWSERSTACK_ACCESS_KEY']
        if not username or not key:
            raise RuntimeError('Missing BrowserStack credentials')
        api = Client('api-cloud.browserstack.com', username, key)
        hub = Client('hub-cloud.browserstack.com', username, key)
        plan = api('/app-automate/plan.json')
        verify_plan(plan)
        report['plan'] = {name: plan.get(name) for name in (
            'automate_plan', 'parallel_sessions_running', 'parallel_sessions_max_allowed', 'queued_sessions')}
        devices = api('/app-automate/devices.json')
        android = [d for d in devices if d.get('os', '').lower() == 'android']
        device = max(android, key=lambda d: tuple(map(int, re.findall(r'\d+', d['os_version']))), default=None)
        if device is None:
            raise RuntimeError('No Android device is available')
        report['device'] = {'name': device['device'], 'os_version': device['os_version']}
        boundary = uuid.uuid4().hex
        upload = (f'--{boundary}\r\nContent-Disposition: form-data; name="url"\r\n\r\n'
                  f'{APP_URL}\r\n--{boundary}--\r\n').encode()
        app = api('/app-automate/upload', 'POST', upload, timeout=120,
                  content_type='multipart/form-data; boundary=' + boundary)
        report['app_url'] = app['app_url']
        # 上传可能耗时，创建前再次检查并发状态；此查询不启动设备。
        verify_plan(api('/app-automate/plan.json'))
        capture(api, hub, out, app['app_url'], device, report)
    except Exception as error:
        report['passed'] = False
        report['error'] = str(error)
    finally:
        if report.get('session_released'):
            try:
                api(f'/app-automate/sessions/{report["session_id"]}.json', 'PUT',
                    {'status': 'passed' if report['passed'] else 'failed',
                     'reason': 'Single bounded FluxDO install/launch check'}, timeout=10)
                details = api(f'/app-automate/sessions/{report["session_id"]}.json', timeout=10)
                details = details.get('automation_session', details)
                report['platform_session'] = {name: details.get(name) for name in (
                    'status', 'duration', 'browser_url', 'device', 'os_version')}
            except Exception as error:
                report['reporting_error'] = str(error)
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
    return 0 if report['passed'] and report['session_released'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
