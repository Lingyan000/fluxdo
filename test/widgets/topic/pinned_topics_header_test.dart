import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/widgets/topic/pinned_topics_header.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [375.0, 812.0]) {
      testWidgets('置顶入口 $brightness 宽度 $width 支持大字体和减少动态效果', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 600);
        addTearDown(tester.view.reset);
        var toggles = 0;
        var reads = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 600),
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: PinnedTopicsHeader(
                        count: 12,
                        unreadCount: 8,
                        expanded: true,
                        markingRead: false,
                        onToggle: () => toggles++,
                        onMarkRead: () => reads++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('pinned-topics-toggle'));
        final mark = find.byKey(const ValueKey('pinned-topics-mark-read'));
        expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(mark).shortestSide, greaterThanOrEqualTo(48));
        expect(
          tester
              .widget<AnimatedRotation>(find.byType(AnimatedRotation))
              .duration,
          Duration.zero,
        );
        await tester.tap(toggle);
        await tester.tap(mark);
        expect(toggles, 1);
        expect(reads, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final mode in SegmentedCardMode.values) {
    testWidgets('置顶标题行随分段卡片样式 $mode 绘制，与话题卡同一套规则', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(extensions: [SegmentedCardStyle(mode: mode)]),
            home: Scaffold(
              body: PinnedTopicsHeader(
                count: 3,
                unreadCount: 0,
                expanded: false,
                markingRead: false,
                onToggle: () {},
              ),
            ),
          ),
        ),
      );
      final item = find.byType(SegmentedCardItem);
      expect(item, findsOneWidget);
      expect(
        find.text(
          tester.element(item).l10n.topics_pinnedCount(3),
        ),
        findsOneWidget,
        reason: '标题行显示置顶话题数量，不是分段数',
      );
      final material = tester.widget<Material>(
        find.descendant(of: item, matching: find.byType(Material)).first,
      );
      switch (mode) {
        case SegmentedCardMode.segmented:
          expect(material.color, isNot(Colors.transparent));
        case SegmentedCardMode.outlined:
          // 描边模式：外框由条目自己画（折叠时整框都在这一行）
          expect(
            find.descendant(of: item, matching: find.byType(CustomPaint)),
            findsWidgets,
          );
        case SegmentedCardMode.flat:
          expect(material.color, Colors.transparent);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
