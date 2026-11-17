import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('应用使用独立 UI 包，避免新旧主题与组件类型混用', () {
    final legacyUiImport = RegExp(
      r'''(?:import|export)\s+['"]package:(?:flutter/(?:material|cupertino)\.dart|flutter_localizations/flutter_localizations\.dart)['"]''',
    );
    final violations = <String>[];
    final workspacePackage = RegExp(
      r'^resolution:\s*workspace\s*$',
      multiLine: true,
    );
    final roots = [
      Directory('lib'),
      for (final package in Directory(
        'packages',
      ).listSync().whereType<Directory>())
        if (File('${package.path}/pubspec.yaml').existsSync() &&
            workspacePackage.hasMatch(
              File('${package.path}/pubspec.yaml').readAsStringSync(),
            ) &&
            Directory('${package.path}/lib').existsSync())
          Directory('${package.path}/lib'),
    ];
    for (final file in roots.expand(
      (root) => root.listSync(recursive: true).whereType<File>(),
    )) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final match in legacyUiImport.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('${file.path}:$line');
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          '使用 material_ui / cupertino_ui；本地化委托使用 '
          'GlobalMaterialLocalizations.delegates。第三方旧组件由应用根层兼容桥承接。',
    );
  });
}
