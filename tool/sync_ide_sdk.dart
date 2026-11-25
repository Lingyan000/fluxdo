import 'dart:io';

import '_workspace_cli.dart';

/// 把当前激活的 Flutter SDK 链接到 `.tooling/flutter_sdk`，供 VS Code 与 Android Studio 使用。
Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  final quiet = args.contains('--quiet');
  final checkOnly = args.contains('--check');

  final changedOrStale = await syncIdeFlutterSdkLink(
    quiet: quiet,
    checkOnly: checkOnly,
  );
  if (checkOnly && changedOrStale) {
    exit(1);
  }
}
