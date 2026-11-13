import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('无边框输入框统一用 withoutBorder()', () {
    // 主题的 enabledBorder / focusedBorder 优先于输入框自己的 border，只写
    // `border: InputBorder.none` 在描边、下划线风格的主题下仍会画出框。
    final rawNone = RegExp(r'\bborder:\s*InputBorder\.none\b');
    final comments = RegExp(r'//[^\n]*|/\*[\s\S]*?\*/');
    final violations = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('.g.dart')) {
        continue;
      }
      final source = file.readAsStringSync().replaceAllMapped(
        comments,
        (match) => '\n' * '\n'.allMatches(match[0]!).length,
      );
      for (final match in rawNone.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('${file.path}:$line');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '用 InputDecoration(...).withoutBorder()（common_ui）清掉各状态的边框。',
    );
  });
}
