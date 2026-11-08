import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('应用路由与弹窗使用统一手势入口', () {
    // Guard the application boundary. Framework subclasses belong in common_ui;
    // application PopupRoutes explicitly integrate InterruptibleRoute instead.
    final rawEntry = RegExp(
      r'\b(MaterialPageRoute|CupertinoPageRoute|PageRouteBuilder|DialogRoute|'
      r'RawDialogRoute|ModalBottomSheetRoute|showDialog|showGeneralDialog|'
      r'showModalBottomSheet)\s*(?:<[^;{}()]*>)?\s*\(',
    );
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
      for (final match in rawEntry.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('${file.path}:$line ${match[1]}');
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          '使用 InteractionPageRoute / InteractionPageRouteBuilder / '
          'showInteractionDialog 或 showAppDialog / showAppBottomSheet，'
          '避免新页面重新引入关闭动画阻塞输入。',
    );
  });
}
