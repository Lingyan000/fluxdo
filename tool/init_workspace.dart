import 'dart:io';

import '_workspace_cli.dart';
import 'project_prep.dart' as project_prep;

/// 首次克隆或新建 worktree 的一键初始化脚本。
///
/// 禁止依赖任何 `package:*`（执行时尚未生成 `.dart_tool/package_config.json`）。
Future<void> main(List<String> args) async {
  await runInitWorkspace();
}

Future<void> runInitWorkspace({
  Future<void> Function({required bool force})? onGenerateL10n,
}) async {
  enterWorkspaceRoot();
  final watch = Stopwatch()..start();

  stdout.writeln('==> [1/4] 初始化 packages/fluxdo_render 子模块');
  await runOrExit(
    title: '同步 git 子模块',
    executable: 'git',
    arguments: const ['submodule', 'update', '--init', 'packages/fluxdo_render'],
  );

  stdout.writeln('==> [2/4] 同步 IDE Flutter SDK 链接');
  await syncIdeFlutterSdkLink();

  stdout.writeln('==> [3/4] 初始化 workspace 依赖 (melos bootstrap)');
  await ensurePubGet();
  await runOrExit(
    title: '执行 melos bootstrap',
    executable: Platform.resolvedExecutable,
    arguments: const ['run', 'melos', 'bootstrap'],
  );

  stdout.writeln('==> [4/4] 同步项目生成物与证书资源');
  await project_prep.runProjectPrep(
    const ['app'],
    onGenerateL10n: onGenerateL10n,
  );

  watch.stop();
  stdout.writeln(
    '==> 工作区初始化完成 (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)',
  );
}
