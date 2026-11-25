import 'dart:io';

/// 最小设备壳只验证生产脚本引擎与协议，不加载应用账号或外部服务。
Future<void> main() async {
  final root = Directory.current.absolute;
  final target = Directory('${root.path}/build/plugin-mobile-smoke');
  if (await target.exists()) throw StateError('冒烟目录已存在，请使用新的工作区');
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final result = await Process.run(flutter, [
    'create',
    '--platforms=android,ios',
    '--empty',
    '--project-name',
    'plugin_mobile_smoke',
    target.path,
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  String path(String relative) =>
      '${root.path.replaceAll(Platform.pathSeparator, '/')}/$relative';
  await File('${target.path}/pubspec.yaml').writeAsString('''
name: plugin_mobile_smoke
version: 1.0.0+1
publish_to: none
environment:
  sdk: ^3.14.0
dependencies:
  flutter:
    sdk: flutter
  qjs:
    path: ${path('packages/qjs')}
  fluxdo_plugin_runtime:
    path: ${path('packages/fluxdo_plugin_runtime')}
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
flutter:
  assets:
    - assets/data.mjs
''');
  await Directory('${target.path}/assets').create();
  await File(path('test/fixtures/metaverse/sdk/data.mjs'))
      .copy('${target.path}/assets/data.mjs');
  await File(
    path('lib/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart'),
  ).copy('${target.path}/lib/script_engine.dart');
  await Directory('${target.path}/integration_test').create();
  await File(path('tool/plugin_tools/mobile_smoke_test.txt'))
      .copy('${target.path}/integration_test/runtime_test.dart');
  stdout.writeln(target.path);
}
