"""读取已安装模拟器的公开应用 Bundle 元数据，不使用私有 WebKit API。"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import http.server
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--ios-version', help='额外启动指定版本的系统 Safari，读取实际 UA')
args = parser.parse_args()
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
results = []
for runtime in runtimes:
    if not runtime.get('name', '').startswith('iOS '):
        continue
    folder = Path(runtime['bundlePath']) / 'Contents/Resources/RuntimeRoot'
    row = {'runtime': runtime, 'bundles': []}
    for name in ('MobileSafari', 'SafariViewService'):
        path = folder / 'Applications' / (name + '.app') / 'Info.plist'
        info = {'path': str(path), 'exists': path.exists()}
        if path.exists():
            data = plistlib.loads(path.read_bytes())
            info.update({k: v for k, v in data.items() if k.startswith('CFBundle') or k == 'SafariProductVersion'})
        row['bundles'].append(info)
    results.append(row)
args.output.write_text(json.dumps(results, indent=2, default=str))
print(json.dumps([{'runtime': r['runtime']['version'],
                   'versions': [b.get('CFBundleShortVersionString') for b in r['bundles']]}
                  for r in results]), flush=True)

if args.ios_version:
    runtime = next(r for r in runtimes if r.get('version') == args.ios_version and r.get('isAvailable'))
    device = next(d for d in runtime['supportedDeviceTypes'] if d.get('productFamily') == 'iPhone')
    udid = subprocess.check_output(['xcrun', 'simctl', 'create', 'FluxDO-Safari-Identity',
                                   device['identifier'], runtime['identifier']], text=True).strip()
    received = threading.Event()
    record = {'runtime_version': runtime['version']}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            record['user_agent'] = self.headers.get('User-Agent')
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Safari identity captured')
            received.set()

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=240)
        subprocess.run(['xcrun', 'simctl', 'openurl', udid,
                        f'http://localhost:{server.server_port}/identity'], check=True, timeout=60)
        if not received.wait(90):
            raise RuntimeError('Safari did not reach local identity endpoint')
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        server.shutdown()
        # 先落盘，清理故障不能让已收到的 UA 证据丢失。
        args.output.with_name('safari-user-agent.json').write_text(json.dumps(record, indent=2))
        record['cleanup_errors'] = []
        for action in ('shutdown', 'delete'):
            try:
                subprocess.run(['xcrun', 'simctl', action, udid], timeout=60, check=True)
            except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
                record['cleanup_errors'].append(str(error))
        args.output.with_name('safari-user-agent.json').write_text(json.dumps(record, indent=2))
        if record['cleanup_errors'] and 'error' not in record:
            raise RuntimeError('Simulator cleanup failed; captured evidence was retained')
