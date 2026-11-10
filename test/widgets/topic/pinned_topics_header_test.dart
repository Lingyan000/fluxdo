import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/widgets/topic/pinned_topics_header.dart';

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
}
