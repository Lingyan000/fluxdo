import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
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
