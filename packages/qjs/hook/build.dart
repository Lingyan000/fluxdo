import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // 本地修补过原生入口，必须从源码编译，不能载入上游未修补的预编译库。
    final cbuilder = CBuilder.library(
      name: input.packageName,
      assetName: '${input.packageName}.dart',
      sources: [
        'quickjs/dtoa.c',
        'quickjs/libregexp.c',
        'quickjs/libunicode.c',
        'quickjs/quickjs.c',
        'src/qjs_dart.c',
      ],
      includes: [
        'quickjs',
        'src',
      ],
      defines: {
        '_GNU_SOURCE': '1',
        'CONFIG_VERSION': '"0.17.0"',
        'QUICKJS_NG_BUILD': '1',
        'NDEBUG': '1',
      },
      std: 'c11',
      flags: [if (input.config.code.targetOS == OS.windows) '/utf-8'],
      libraries: [
        if (input.config.code.targetOS != OS.windows) 'm',
        if (input.config.code.targetOS == OS.linux || input.config.code.targetOS == OS.macOS || input.config.code.targetOS == OS.iOS) 'pthread',
      ],
    );
    await cbuilder.run(
      input: input,
      output: output,
    );
  });
}
