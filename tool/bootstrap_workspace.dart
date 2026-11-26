import 'dart:io';

import '_workspace_cli.dart';

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  await syncIdeFlutterSdkLink(quiet: true);
  await ensurePubGet();
  await runOrExit(
    title: '执行 melos bootstrap',
    executable: Platform.resolvedExecutable,
    arguments: const ['run', 'melos', 'bootstrap'],
  );
}
