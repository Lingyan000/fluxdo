"""只在一次性 Android 模拟器检查完整应用启动、断网与恢复；不操作用户设备。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

PACKAGE = 'com.github.lingyan000.fluxdo'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'passed': False, 'full_flutter_app': True, 'physical_device': False,
              'scope': 'Release app startup and emulator network disconnect/reconnect; not radio handoff or CF acceptance',
              'apk_sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest()}
    changed = False
    owned_emulator = False
    def adb(*command, timeout=20):
        return subprocess.check_output(['adb', *command], timeout=timeout).decode(errors='replace').strip()
    def capture(name):
        pid = adb('shell', 'pidof', PACKAGE)
        if not pid or not pid.isdecimal(): raise RuntimeError('Full app process missing or ambiguous')
        maps = adb('shell', 'cat', f'/proc/{pid}/maps')
        loaded = 'libfluxdo_net.so' in maps
        png = subprocess.check_output(['adb', 'exec-out', 'screencap', '-p'], timeout=15)
        (args.output/(name+'.png')).write_bytes(png)
        return {'pid': int(pid), 'core_library_loaded': loaded,
                'wifi_enabled': adb('shell', 'settings', 'get', 'global', 'wifi_on'),
                'mobile_data_enabled': adb('shell', 'settings', 'get', 'global', 'mobile_data')}
    try:
        if adb('shell', 'getprop', 'ro.kernel.qemu') != '1':
            raise RuntimeError('This check only permits an emulator')
        owned_emulator = True
        result['android_version'] = adb('shell', 'getprop', 'ro.build.version.release')
        webview = adb('shell', 'dumpsys', 'webviewupdate')
        result['webview_provider'] = next((line.strip() for line in webview.splitlines()
                                          if 'Current WebView package' in line), 'unknown')
        adb('root'); adb('wait-for-device')
        adb('install', str(args.apk), timeout=90)
        adb('logcat', '-c')
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE+'/.MainActivity')
        time.sleep(10)
        result['online'] = capture('online')
        changed = True
        adb('shell', 'svc', 'wifi', 'disable'); adb('shell', 'svc', 'data', 'disable')
        time.sleep(4)
        result['offline'] = capture('offline')
        adb('shell', 'svc', 'wifi', 'enable'); adb('shell', 'svc', 'data', 'enable')
        time.sleep(8)
        result['restored'] = capture('restored')
        result['passed'] = (all(result[phase]['core_library_loaded'] for phase in ('online', 'offline', 'restored'))
                            and len({result[phase]['pid'] for phase in ('online', 'offline', 'restored')}) == 1
                            and result['offline']['wifi_enabled'] == '0'
                            and result['offline']['mobile_data_enabled'] == '0'
                            and result['restored']['wifi_enabled'] == '1')
    except Exception as error:
        result['error'] = str(error)
    finally:
        if changed:
            try:
                adb('shell', 'svc', 'wifi', 'enable'); adb('shell', 'svc', 'data', 'enable')
                result['network_restored'] = True
            except Exception as error:
                result['cleanup_error'] = str(error); result['passed'] = False
        if owned_emulator:
            try:
                logs = adb('logcat', '-d', '-v', 'threadtime', 'FluxdoNet:I', 'flutter:I', 'AndroidRuntime:E', '*:S')
                (args.output/'application.log').write_text(logs)
                adb('shell', 'am', 'force-stop', PACKAGE)
                result['app_stopped'] = True
            except Exception as error:
                result['log_or_stop_error'] = str(error); result['passed'] = False
        (args.output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
