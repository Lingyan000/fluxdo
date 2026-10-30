import 'dart:io';

import 'package:fluxdo/l10n/s.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

void main() {
  testWidgets('工具分组通过 headingLevel 暴露移动端标题语义', (tester) async {
    final semantics = tester.ensureSemantics();
    final anchor = ComposerToolsAnchor()
      ..actions = [
        ComposerToolAction(
          id: 'bold',
          label: '加粗',
          icon: const Icon(Icons.format_bold),
          run: () {},
        ),
      ];
    addTearDown(anchor.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: ComposerExpandedTools(
              anchor: anchor,
              animation: const AlwaysStoppedAnimation(1),
              flyingIds: const {},
            ),
          ),
        ),
      ),
    );
    final heading = find.byKey(const ValueKey('composer-tools-group-format'));
    expect(heading, findsOneWidget);
    expect(tester.getSemantics(heading).getSemanticsData().headingLevel, 2);
    semantics.dispose();
  });

  test('背景采样仅在旧版 GLES 纹理约定下翻转', () {
    // 源码契约测试不能代替 GLES 真机像素验证。
    const guard =
        '#if defined(IMPELLER_TARGET_OPENGLES) && '
        '!defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)';
    for (final path in [
      'shaders/progressive_top_blur.frag',
      'packages/common_ui/shaders/glass_surface.frag',
    ]) {
      final shader = File(path).readAsStringSync();
      expect(shader, contains(guard), reason: path);
      expect(shader, isNot(contains('#ifdef IMPELLER_TARGET_OPENGLES')));
    }
    final blur = File('shaders/progressive_top_blur.frag').readAsStringSync();
    expect(blur, isNot(contains('yTop = u_size.y - frag.y')));
  });
}
