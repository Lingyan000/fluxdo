import 'dart:io';

import 'package:slang/src/builder/builder/slang_file_collection_builder.dart';
import 'package:slang/src/runner/generate.dart';

import '_workspace_cli.dart';
import 'gen_slang_compat.dart' as compat;

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

  if (!checkOnly && !force && isL10nUpToDate()) {
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
    writeL10nStamp();
  }

  stdout.writeln(checkOnly ? '==> 校验通过' : '==> 完成');
  return !checkOnly;
}
