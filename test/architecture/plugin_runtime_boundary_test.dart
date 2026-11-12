import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test('插件服务域名留在插件资源，宿主能力不携带具体服务地址', () {
    final hosts = <String>{};
    for (final file in Directory(
      'plugins',
    ).listSync(recursive: true).whereType<File>()) {
      if (path.basename(file.path) != 'plugin.json') continue;
      final raw = jsonDecode(file.readAsStringSync()) as Map;
      hosts.addAll(
        ((raw['permissions'] as Map)['network'] as List).cast<String>(),
      );
    }
    final violations = <String>[];
    for (final file in Directory(
      'lib/modules/metaverse/plugin',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final host in hosts) {
        if (source.contains(host)) violations.add('${file.path} → $host');
      }
    }
    expect(violations, isEmpty);
  });

  test('宿主桥与脚本 SDK 仅导出公共能力，服务查询和订单由插件实现', () {
    final sources = [
      File('lib/modules/metaverse/plugin/metaverse_plugin_host.dart'),
      File('lib/modules/metaverse/plugin/metaverse_plugin_network.dart'),
      File(
        'packages/fluxdo_plugin_runtime/lib/src/metaverse_plugin_prelude.dart',
      ),
    ];
    for (final file in sources) {
      expect(
        file.readAsStringSync(),
        isNot(
          matches(
            r'auth\.query|checkout\.|MetaverseServiceSession|MetaverseOrderIntent',
          ),
        ),
        reason: file.path,
      );
    }
  });

  test('插件运行时仅依赖 Dart 与自身协议，应用和界面适配留在宿主', () {
    final root = Directory('packages/fluxdo_plugin_runtime/lib').absolute;
    final directives = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''');
    final violations = <String>[];
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in directives.allMatches(file.readAsStringSync())) {
        final target = match[1]!;
        final uri = Uri.parse(target);
        final allowed =
            uri.scheme == 'dart' ||
            (uri.scheme == 'package' &&
                uri.pathSegments.first == 'fluxdo_plugin_runtime') ||
            (!uri.hasScheme &&
                path.isWithin(
                  root.path,
                  path.normalize(path.join(file.parent.path, target)),
                ));
        if (!allowed) violations.add('${file.path} → $target');
      }
    }
    expect(violations, isEmpty);
  });
}
