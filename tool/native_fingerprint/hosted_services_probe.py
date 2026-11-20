"""在一次性模拟器读取公开 H3 服务；只存诊断证据，不向生产模板导入未知字段。"""
import argparse
import json
from pathlib import Path
import subprocess
import time

PACKAGE = 'com.fluxdo.fingerprintprobe'


def shape(value, path=''):
    """记录字段及类型而不是把第三方返回的哈希视作完整模板。"""
    if isinstance(value, dict):
        return {key: shape(child, path+'.'+key) for key, child in value.items()}
    if isinstance(value, list):
        return {'type': 'array', 'count': len(value), 'examples': [shape(v, path+'[]') for v in value[:2]]}
    return type(value).__name__


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    def adb(*command, timeout=15):
        return subprocess.check_output(['adb', *command], text=True, timeout=timeout).strip()
    if adb('shell', 'getprop', 'ro.kernel.qemu') != '1':
        raise RuntimeError('Only an ephemeral emulator is permitted')
    services = json.loads(Path(__file__).with_name('hosted_services.json').read_text())
    summary = []
    for service in services:
        entry = {'service': service['name'], 'url': service['url'], 'production_template_imported': False}
        try:
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('shell', 'run-as', PACKAGE, 'rm', '-f', 'files/hosted-result.json')
            adb('shell', 'am', 'start', '-W', '-n', PACKAGE+'/.HostedServiceActivity', '--es', 'url', service['url'])
            deadline = time.monotonic()+55
            while True:
                result = subprocess.run(['adb', 'shell', 'run-as', PACKAGE, 'cat', 'files/hosted-result.json'], capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    data = json.loads(result.stdout);break
                if time.monotonic() >= deadline: raise TimeoutError('Hosted service driver timeout')
                time.sleep(1)
            (args.output/(service['name']+'.json')).write_text(json.dumps(data, indent=2)+'\n')
            entry.update(engine=data['engine'], os=data['os'], webview=data['webview'], ssl_errors=data['ssl_errors'])
            entry['attempts'] = []
            for attempt in data['attempts']:
                item = {k:v for k,v in attempt.items() if k != 'body'}
                try:
                    body = json.loads(attempt.get('body', ''))
                    item['json_shape'] = shape(body)
                except ValueError:
                    item['json_shape'] = None
                entry['attempts'].append(item)
        except Exception as error:
            entry['error'] = str(error)
        finally:
            adb('shell', 'am', 'force-stop', PACKAGE)
            entry['app_stopped'] = True
            summary.append(entry)
            (args.output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2))
    # 服务不支持/拒绝请求是有效诊断结果；宿主或取证失败才算执行失败。
    return int(any('error' in entry for entry in summary))


if __name__ == '__main__':
    raise SystemExit(main())
