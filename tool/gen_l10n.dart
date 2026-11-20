import 'dart:io';

import '_workspace_cli.dart';
import 'gen_slang_compat.dart' as compat;
import 'package:slang/src/builder/builder/slang_file_collection_builder.dart';
import 'package:slang/src/runner/generate.dart';

// slang 暂无稳定的公开生成 API，这里直接调用其内部 runner。
// 对应依赖已在 pubspec.yaml 中锁定生成器版本，升级时请一起验证这个脚本。
Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  final checkOnly = args.contains('--check');

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

  stdout.writeln(checkOnly ? '==> 校验通过' : '==> 完成');
}
