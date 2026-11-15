"""读取已安装模拟器的公开应用 Bundle 元数据，不使用私有 WebKit API。"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
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
print(json.dumps(results, indent=2, default=str))
