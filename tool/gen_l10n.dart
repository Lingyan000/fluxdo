import 'dart:io';

import 'package:slang/src/builder/builder/slang_file_collection_builder.dart';
import 'package:slang/src/runner/generate.dart';

import '_workspace_cli.dart';
import 'gen_slang_compat.dart' as compat;

const _requiredOutputs = <String>[
  'lib/l10n/slang/strings.g.dart',
  'lib/l10n/generated/app_localizations_compat.g.dart',
];

// slang 暂无稳定的公开生成 API，这里直接调用其内部 runner。
// 对应依赖已在 pubspec.yaml 中锁定生成器版本，升级时请一起验证这个脚本。
Future<void> main(List<String> args) async {
  enterWorkspaceRoot();
  final checkOnly = args.contains('--check');
  final force = args.contains('--force');
  await runGenL10n(checkOnly: checkOnly, force: force);
}

/// 执行国际化代码生成或校验。
///
/// 返回 `true` 表示本次实际执行了生成，`false` 表示命中增量缓存跳过或仅执行了校验。
Future<bool> runGenL10n({bool checkOnly = false, bool force = false}) async {
  enterWorkspaceRoot();

  final stampFile = File(l10nStampPath);
  if (!checkOnly && !force && _isL10nUpToDate(stampFile)) {
    stdout.writeln('==> l10n 生成产物已是最新状态');
    return false;
  }

  stdout.writeln(checkOnly ? '==> 校验 slang 生成结果...' : '==> 生成 slang 代码...');
  final fileCollection = SlangFileCollectionBuilder.readFromFileSystem(
    verbose: false,
  );
  await generateTranslations(fileCollection: fileCollection);

  stdout.writeln(
    checkOnly
        ? '==> 校验 AppLocalizations 兼容层...'
        : '==> 生成 AppLocalizations 兼容层...',
  );
  compat.main(checkOnly ? ['--check'] : const []);

  if (!checkOnly) {
    stampFile.parent.createSync(recursive: true);
    stampFile.writeAsStringSync(_buildL10nStamp());
  }

  stdout.writeln(checkOnly ? '==> 校验通过' : '==> 完成');
  return !checkOnly;
}

bool _isL10nUpToDate(File stampFile) {
  if (!stampFile.existsSync()) {
    return false;
  }
  for (final outputPath in _requiredOutputs) {
    if (!File(outputPath).existsSync()) {
      return false;
    }
  }
  return stampFile.readAsStringSync() == _buildL10nStamp();
}

String _buildL10nStamp() {
  final tracked = <File>[
    File('slang.yaml'),
    File('tool/gen_l10n.dart'),
    File('tool/gen_slang_compat.dart'),
    for (final output in _requiredOutputs) File(output),
    ..._collectArbFiles(),
  ].where((file) => file.existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  return tracked.map((file) {
    final stat = file.statSync();
    return '${file.path}|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
  }).join('\n');
}

Iterable<File> _collectArbFiles() sync* {
  final dir = Directory('lib/l10n/modules');
  if (!dir.existsSync()) {
    return;
  }
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.arb')) {
      yield entity;
    }
  }
}
