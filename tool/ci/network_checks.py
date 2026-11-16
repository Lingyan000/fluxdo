"""常规网络回归入口：本地与 CI 使用相同命令，不访问设备平台。"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONFIG = json.loads(Path(__file__).with_suffix('.json').read_text())


def plan(paths, all_platforms=False):
    ci = any(p.startswith(('tool/ci/', '.github/workflows/network-')) for p in paths)
    core = any(p.startswith('core/net_core/') for p in paths)
    dart = ci or any(p.startswith(('lib/', 'test/', 'packages/', '.agents/')) or
                     p in ('pubspec.yaml', 'pubspec.lock', 'AGENTS.md', '.gitmodules',
                           'analysis_options.yaml', 'tool/gen_l10n.dart', 'tool/project_prep.dart')
                     for p in paths)
    python = ci or core or any(p.startswith('tool/') for p in paths)
    platforms = [dict(platform=row['platform'], os=row['os']) for row in CONFIG['platforms']
                 if all_platforms or core or any(p.startswith(tuple(row['paths'])) for p in paths)]
    return dict(dart=dart, rust=ci or core or any(p.startswith('linux/') for p in paths), python=python, platforms={'include': platforms})


def run(args, cwd=ROOT):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def nonzero_rust_result(output):
    return bool(re.search(r'test result: ok\. [1-9][0-9]* passed; 0 failed;', output))


def python_tests():
    total = 0
    for directory in CONFIG['python_suites']:
        # 每个目录单独 discover，保留现有测试的相对导入方式。
        suite = unittest.TestLoader().discover(str(ROOT / directory), pattern='test_*.py')
        count = suite.countTestCases()
        if count == 0:
            raise RuntimeError(f'没有发现测试: {directory}')
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        if not result.wasSuccessful():
            raise RuntimeError(f'测试失败: {directory}')
        total += count
    print(f'Python total: {total} tests passed', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('task', choices=['plan', 'dart', 'rust', 'python'])
    parser.add_argument('--base')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--all-platforms', action='store_true')
    args = parser.parse_args()
    if args.task == 'plan':
        if args.base and set(args.base) != {'0'}:
            # PR 的 base 可能前进；只计算该分支相对共同祖先的改动。
            paths = subprocess.check_output(['git', 'diff', '--name-only', '-z',
                                             f'{args.base}...{args.head}'], cwd=ROOT).decode().split('\0')
        else:
            paths = ['tool/ci/network_checks.py']
        selected = plan(paths, args.all_platforms)
        print(json.dumps(selected, ensure_ascii=False))
        if os.getenv('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                for key, value in selected.items():
                    output.write(f'{key}={json.dumps(value, separators=(",", ":"))}\n')
                output.write(f'has_platforms={str(bool(selected["platforms"]["include"])).lower()}\n')
    elif args.task == 'dart':
        run(['flutter', 'test', '--no-pub', *CONFIG['dart_tests'], '--reporter', 'expanded'])
        run(['flutter', 'analyze', '--no-pub', *CONFIG['dart_analyze'], *CONFIG['dart_tests']])
    elif args.task == 'rust':
        # 不传模块过滤器，避免模块改名后执行 0 项仍成功。
        command = ['cargo', 'test', '--locked', '--lib', '--', '--test-threads=2']
        print('+ ' + ' '.join(command), flush=True)
        result = subprocess.run(command, cwd=ROOT/'core/net_core', stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        print(result.stdout, end='', flush=True)
        if result.returncode or not nonzero_rust_result(result.stdout):
            raise RuntimeError('Rust 回归失败或未执行任何测试')
    else:
        python_tests()


if __name__ == '__main__':
    main()
