import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/app_icon_provider.dart';
import 'package:fluxdo/widgets/preheat_logo.dart';

void main() {
  for (final style in AppIconStyle.values) {
    for (final brightness in Brightness.values) {
      testWidgets('${style.name} ${brightness.name} 光晕响应交接与减少动态效果', (
        tester,
      ) async {
        final shown = ValueNotifier(false);
        addTearDown(shown.dispose);

        Future<void> pumpLogo({required bool reduceMotion}) =>
            tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: MediaQuery(
                  data: MediaQueryData(disableAnimations: reduceMotion),
                  child: Center(
                    child: PreheatLogo(
                      style: style,
                      entry: const AlwaysStoppedAnimation(1),
                      shown: shown,
                    ),
                  ),
                ),
              ),
            );

        CustomPainter glowPainter() => tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: find.byType(PreheatLogo),
                matching: find.byType(CustomPaint),
              ),
            )
            .first
            .painter!;

        await pumpLogo(reduceMotion: true);
        final hidden = glowPainter();
        await tester.pump(const Duration(seconds: 1));
        expect(glowPainter().shouldRepaint(hidden), isFalse);
        expect(tester.binding.transientCallbackCount, 0);

        shown.value = true;
        await tester.pump();
        final steady = glowPainter();
        expect(steady.shouldRepaint(hidden), isTrue);
        await tester.pump(const Duration(seconds: 1));
        expect(glowPainter().shouldRepaint(steady), isFalse);
        expect(tester.binding.transientCallbackCount, 0);

        // 用户关闭减少动态效果后恢复呼吸，再打开时停在当前阶段。
        await pumpLogo(reduceMotion: false);
        await tester.pump(const Duration(milliseconds: 800));
        final breathing = glowPainter();
        expect(breathing.shouldRepaint(steady), isTrue);
        await pumpLogo(reduceMotion: true);
        expect(glowPainter().shouldRepaint(breathing), isFalse);
        await tester.pump(const Duration(seconds: 1));
        expect(glowPainter().shouldRepaint(breathing), isFalse);
        expect(tester.binding.transientCallbackCount, 0);

        // 交接状态撤回时，光晕也应收起并停止刷新。
        shown.value = false;
        await tester.pump();
        expect(glowPainter().shouldRepaint(hidden), isFalse);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
