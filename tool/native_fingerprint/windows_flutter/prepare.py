"""生成一次性最小 Flutter 工程，生产环境管理类逐字复制并记录摘要。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
output = args.output.resolve()
subprocess.run(['flutter', 'create', '--platforms=windows', '--project-name=h3_probe_host',
                '--empty', '--no-pub', str(output)], check=True, shell=os.name == 'nt')
# 保留当前 Flutter 模板的开发依赖，确保生成的分析配置能解析 lint 包。
generated_pubspec = (output/'pubspec.yaml').read_text()
dev_dependencies = re.search(
    r'(?m)^dev_dependencies:\n(?:[ \t].*\n|[ \t]*\n)*', generated_pubspec)
if dev_dependencies is None:
    raise RuntimeError('Flutter 模板缺少 dev_dependencies，停止生成测试宿主')
(output/'pubspec.yaml').write_text('''name: h3_probe_host
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  material_ui: ^1.11.1
  flutter:
    sdk: flutter
  flutter_inappwebview: 6.2.0-beta.3
''' + dev_dependencies.group(0) + '''dependency_overrides:
  flutter_inappwebview_windows:
    path: ''' + json.dumps(str(repo/'packages/flutter_inappwebview_windows').replace('\\','/')) + '\n')
source = repo/'lib/services/network/fingerprint/windows_h3_probe_environment.dart'
shutil.copy(source, output/'lib/windows_h3_probe_environment.dart')
shutil.copy(Path(__file__).with_name('main.dart'), output/'lib/main.dart')
(output/'production-source.json').write_text(json.dumps({'source':str(source.relative_to(repo)),
 'sha256':hashlib.sha256(source.read_bytes()).hexdigest(), 'full_flutter_app':False}, indent=2)+'\n')
