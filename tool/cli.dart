import 'dart:io';

import '_workspace_cli.dart';
import 'flutterw.dart' as flutterw;
import 'gen_l10n.dart' as gen_l10n;
import 'init_workspace.dart' as init_workspace;
import 'project_prep.dart' as project_prep;
import 'project_tasks.dart' as project_tasks;
import 'release.dart' as release;

/// FluxDO 统一单进程 CLI 入口（供 `mise.toml` 各任务直接调用）。
///
/// 通过同进程直接调用各模块，消除原先多层 Dart VM 嵌套冷启动，
/// 同时保留原有 `tool/flutterw.dart`、`tool/project_prep.dart`、`tool/project_tasks.dart`
/// 的独立入口兼容性给 CI、IDE 与测试。
Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln(_usage);
    return;
  }

  final command = args.first;
  final rest = args.sublist(1);

  switch (command) {
    case 'init':
      await init_workspace.runInitWorkspace(
        onGenerateL10n: _inProcessGenL10n,
      );
      return;
    case 'bootstrap':
      await _runBootstrap();
      return;
    case 'sync':
      await project_prep.runProjectPrep(
        const ['app'],
        forceL10n: rest.contains('--force'),
        onGenerateL10n: _inProcessGenL10n,
      );
      return;
    case 'sdk:link':
      final changedOrStale = await syncIdeFlutterSdkLink(
        quiet: rest.contains('--quiet'),
        checkOnly: rest.contains('--check'),
      );
      if (rest.contains('--check') && changedOrStale) {
        exit(1);
      }
      return;
    case 'l10n':
      await gen_l10n.runGenL10n(
        checkOnly: rest.contains('--check'),
        force: rest.contains('--force'),
      );
      return;
    case 'certs':
      await project_prep.runProjectPrep(const ['certs']);
      return;
    case 'doctor':
      await project_prep.runProjectPrep(
        ['doctor', ...rest],
        onNativeDoctor: (doctorArgs) => project_tasks.runProjectTasks(
          ['native:doctor', ...doctorArgs],
          onProjectPrep: _inProcessPrep,
        ),
      );
      return;
    case 'clean':
      await project_tasks.runProjectTasks(
        const ['app:clean'],
        onProjectPrep: _inProcessPrep,
      );
      return;
    case 'rebuild':
      await project_tasks.runProjectTasks(
        ['app:rebuild', ...rest],
        onProjectPrep: _inProcessPrep,
        onFlutterBuild: (buildArgs) => _runFlutter(['build', ...buildArgs]),
      );
      return;
    case 'dev':
    case 'run':
      await _runFlutter(['run', ...rest]);
      return;
    case 'build':
    case 'drive':
      await _runFlutter([command, ...rest]);
      return;
    case 'test':
      await project_tasks.runProjectTasks(
        ['test:all', ...rest],
        onProjectPrep: _inProcessPrep,
      );
      return;
    case 'native':
      await project_tasks.runProjectTasks(
        ['native:prepare', ...rest],
        onProjectPrep: _inProcessPrep,
      );
      return;
    case 'release:check':
      await project_tasks.runProjectTasks(
        ['release:prepare', ...rest],
        onProjectPrep: _inProcessPrep,
      );
      return;
    case 'release':
      await release.runRelease(
        rest,
        onReleasePrepare: (prepareArgs) => project_tasks.runProjectTasks(
          prepareArgs,
          onProjectPrep: _inProcessPrep,
        ),
      );
      return;
    case 'prerelease':
      await release.runRelease(
        ['--track', 'prerelease', ...rest],
        onReleasePrepare: (prepareArgs) => project_tasks.runProjectTasks(
          prepareArgs,
          onProjectPrep: _inProcessPrep,
        ),
      );
      return;
    default:
      stderr.writeln('未知 CLI 子命令: $command');
      stderr.writeln(_usage);
      exit(64);
  }
}

Future<void> _inProcessGenL10n({required bool force}) async {
  await gen_l10n.runGenL10n(force: force);
}

Future<void> _inProcessPrep(String mode) {
  return project_prep.runProjectPrep(
    [mode],
    onGenerateL10n: _inProcessGenL10n,
  );
}

Future<void> _runFlutter(List<String> flutterArgs) {
  return flutterw.runFlutterWrapper(
    flutterArgs,
    onProjectPrep: _inProcessPrep,
    onNativePrepare: (nativeArgs) => project_tasks.runProjectTasks(
      nativeArgs,
      onProjectPrep: _inProcessPrep,
    ),
  );
}

Future<void> _runBootstrap() async {
  await syncIdeFlutterSdkLink(quiet: true);
  await ensurePubGet();
  await runOrExit(
    title: '执行 melos bootstrap',
    executable: Platform.resolvedExecutable,
    arguments: const ['run', 'melos', 'bootstrap'],
  );
}

const _usage = '''
用法:
  dart tool/cli.dart <command> [args...]

常用命令（不与 mise 内置命令重名时可直接 mise <command>，重名的 sync/doctor 用 mise r <command>）:
  init            新克隆 / 新 worktree 一键初始化（子模块 + SDK 链接 + bootstrap + sync）
  bootstrap       初始化 workspace 依赖与链接
  sync            同步依赖、l10n、证书与 IDE SDK 链接
  sdk:link        把当前 Flutter SDK 链接到 .tooling/flutter_sdk
  doctor          检查开发环境与生成产物
  l10n            生成国际化代码（支持 --force / --check）
  certs           生成并同步代理证书资源
  dev             执行 flutter run（支持 macos/windows/linux/ios/android/chrome 简写）
  build           执行 flutter build
  drive           执行 flutter drive
  clean           执行 flutter clean 并重置缓存指纹
  rebuild         先 clean 再 build
  test            执行工作区测试
  native          准备平台原生产物
  release:check   发版前检查、analyze、test
  release         发版向导（无参进入交互流程）
  prerelease      预发布发版向导
''';
