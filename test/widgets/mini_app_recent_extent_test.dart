import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_launch_shelf.dart';

void main() {
  for (final scale in [1.0, 1.8]) {
    testWidgets('最近应用预告尺寸覆盖首卡、间隔和末卡，字号 $scale', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final apps = List.generate(8, (i) => MiniApp(id: '$i', name: '应用$i'));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: MiniAppRecentSection(
                  apps: apps,
                  onOpen: (_) {},
                  onInfo: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      final featured = 208 * scale.clamp(1, 1.35);
      final ordinary = 104 * scale.clamp(1, 1.4);
      final total = 32 + featured + 7 * ordinary + 7 * 8;
      expect(
        tester.getSize(find.byKey(const ValueKey('mini-app-recent-0'))).width,
        closeTo(featured, .01),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(scroll.position.maxScrollExtent, closeTo(total - 360, .01));
      final last = find.byKey(const ValueKey('mini-app-recent-7'));
      expect(tester.getSize(last).width, closeTo(ordinary, .01));
      expect(tester.getRect(last).right, closeTo(344, .01));
      expect(tester.takeException(), isNull);
    });
  }
}
