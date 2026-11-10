import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 圆角字面量守卫：界面圆角必须经形状 token 换算（`context.shapes` /
/// `UiShapes.current`），才能跟随主题的圆角风格。
///
/// 只拦数字字面量：按尺寸算出的圆形（`size / 2`）不属于风格圆角。
/// 主题层本身（lib/theme/）与生成代码不在约束内。
void main() {
  test('lib 中不新增写死的数字圆角', () {
    final pattern = RegExp(
      r'(?<![A-Za-z0-9_.])(BorderRadius|Radius)\.circular\(\s*\d+(\.\d+)?\s*\)',
    );
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') ||
          path.endsWith('.g.dart') ||
          path.startsWith('lib/theme/')) {
        continue;
      }
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          offenders.add('$path:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '请改用 context.shapes.borderRadius(N) / radius(N)，'
          '无 context 时用 UiShapes.current：\n${offenders.join('\n')}',
    );
  });
}
