"""安装并启动本次构建的完整 iOS 应用；最多一个有界会话，不登录、不发布内容。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import time
import uuid
import zipfile

from browserstack_core import API, check_plan


def application_identity(ipa):
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist()
                 if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(names) != 1:
            raise ValueError('Expected exactly one root application')
        info = plistlib.loads(archive.read(names[0]))
        if info.get('CFBundleIdentifier') != 'com.github.lingyan000.fluxdo':
            raise ValueError('Expected the full FluxDO application')
        return {key: info.get(key) for key in (
            'CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'MinimumOSVersion')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ios-major', type=int, default=26)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'passed': False, 'scope': 'Full release app install and launch only; not H3, login or CF acceptance',
              'maximum_session_creations': 1, 'observation_budget_seconds': 120,
              'session_released': False, 'remaining_free_minutes_verified': False}
    session = None
    started = None
    try:
        result['application'] = application_identity(args.ipa)
        result['ipa_sha256'] = hashlib.sha256(args.ipa.read_bytes()).hexdigest()
        auth = 'Basic '+base64.b64encode(':'.join(os.environ[k] for k in (
            'BROWSERSTACK_USERNAME', 'BROWSERSTACK_ACCESS_KEY')).encode()).decode()
        api, hub = API('api-cloud.browserstack.com', auth), API('hub-cloud.browserstack.com', auth)
        check_plan(api('/app-automate/plan.json'))
        devices = [d for d in api('/app-automate/devices.json') if d.get('os', '').lower() == 'ios'
                   and str(d.get('os_version', '')).split('.')[0] == str(args.ios_major)
                   and d.get('device', '').startswith('iPhone')]
        if not devices:
            raise RuntimeError('Requested iPhone version unavailable; no fallback')
        device = sorted(devices, key=lambda d: d['device'])[0]
        result['requested_device'] = {k: device[k] for k in ('device', 'os_version')}
        boundary = uuid.uuid4().hex
        payload = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="fluxdo.ipa"\r\n'
                   'Content-Type: application/octet-stream\r\n\r\n').encode()+args.ipa.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
        uploaded = api('/app-automate/upload', 'POST', payload, timeout=120,
                       content_type='multipart/form-data; boundary='+boundary)
        check_plan(api('/app-automate/plan.json'))
        caps = {'platformName': 'iOS', 'appium:automationName': 'XCUITest',
                'appium:deviceName': device['device'], 'appium:platformVersion': device['os_version'],
                'appium:app': uploaded['app_url'], 'appium:newCommandTimeout': 30,
                'appium:autoAcceptAlerts': True, 'bstack:options': {
                    'projectName': 'FluxDO', 'buildName': 'full-ios-'+os.environ.get('GITHUB_RUN_ID', 'local'),
                    'sessionName': 'One bounded full release app launch', 'idleTimeout': 30,
                    'networkLogs': False, 'debug': False, 'video': False}}
        started = time.monotonic()
        result['creation_requests_sent'] = 1
        response = hub('/wd/hub/session', 'POST', {'capabilities': {'alwaysMatch': caps}}, timeout=60)
        candidate = response.get('value', {}).get('sessionId') or response.get('sessionId')
        if not candidate or not re.fullmatch(r'[A-Za-z0-9-]+', candidate):
            raise RuntimeError('No valid session id; no retry')
        session = candidate
        result['session_id'] = session
        def command(path, method='GET', body=None):
            remaining = started+120-time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Device budget exhausted')
            return hub(f'/wd/hub/session/{session}/{path}', method, body, timeout=min(10, remaining))['value']
        # 只读查看前台应用和界面，不点击登录、同意条款或执行社区操作。
        time.sleep(8)
        active = command('execute/sync', 'POST', {'script': 'mobile: activeAppInfo', 'args': []})
        result['active_bundle_id'] = active.get('bundleId')
        source = command('source')
        (args.output/'launch.xml').write_text(source)
        screenshot = command('screenshot')
        (args.output/'launch.png').write_bytes(base64.b64decode(screenshot, validate=True))
        result['passed'] = (result['active_bundle_id'] == result['application']['CFBundleIdentifier']
                            and 'XCUIElementTypeApplication' in source)
    except Exception as error:
        result['error'] = str(error)
    finally:
        if session:
            try:
                hub(f'/wd/hub/session/{session}', 'DELETE', timeout=15)
                result['session_released'] = True
            except Exception as error:
                result['cleanup_error'] = str(error)
                result['passed'] = False
        if started is not None:
            result['local_session_window_seconds'] = round(time.monotonic()-started, 2)
            if session is None:
                result['creation_outcome'] = 'Unknown without session id; no retry; idle timeout 30 seconds'
        if session and result['session_released']:
            try:
                data = api(f'/app-automate/sessions/{session}.json')
                info = data.get('automation_session', data)
                result['platform_session'] = {k: info.get(k) for k in ('status', 'duration', 'device', 'os_version')}
            except Exception as error:
                result['metadata_error'] = str(error)
        (args.output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result, indent=2))
    return 0 if result['passed'] and result['session_released'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
