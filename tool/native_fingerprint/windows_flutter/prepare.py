"""生成一次性最小 Flutter 工程，生产环境管理类逐字复制并记录摘要。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
output = args.output.resolve()
subprocess.run(['flutter', 'create', '--platforms=windows', '--project-name=h3_probe_host',
                '--empty', '--no-pub', str(output)], check=True, shell=True)
(output/'pubspec.yaml').write_text('''name: h3_probe_host
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  flutter:
    sdk: flutter
  flutter_inappwebview: 6.2.0-beta.3
dependency_overrides:
  flutter_inappwebview_windows:
    path: ''' + json.dumps(str(repo/'packages/flutter_inappwebview_windows').replace('\\','/')) + '\n')
source = repo/'lib/services/network/fingerprint/windows_h3_probe_environment.dart'
shutil.copy(source, output/'lib/windows_h3_probe_environment.dart')
shutil.copy(Path(__file__).with_name('main.dart'), output/'lib/main.dart')
(output/'production-source.json').write_text(json.dumps({'source':str(source.relative_to(repo)),
 'sha256':hashlib.sha256(source.read_bytes()).hexdigest(), 'full_flutter_app':False}, indent=2)+'\n')
