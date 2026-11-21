import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/mention_user.dart';
import 'package:fluxdo/widgets/mention/mention_autocomplete.dart';
import 'package:fluxdo/widgets/mention/mention_candidate_list.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('提及候选按实际行高滚动，循环选择与立即关闭 scale=$scale', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  child: MentionAutocomplete(
                    controller: controller,
                    focusNode: focus,
                    debounceMs: 10,
                    dataSource: (_) async => MentionSearchResult(
                      users: [
                        for (var i = 0; i < 12; i++)
                          MentionUser(
                            username: 'user_$i',
                            name: i.isEven ? '社区用户 $i' : null,
                          ),
                      ],
                      groups: const [
                        MentionGroup(name: 'staff', fullName: '社区团队'),
                      ],
                    ),
                    child: TextField(
                      controller: controller,
                      focusNode: focus,
                      maxLines: 3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      final list = find.byType(MentionCandidateList);
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;

      void expectVisible(String text) {
        final row = find
            .ancestor(of: find.text(text), matching: find.byType(InkWell))
            .first;
        final rect = tester.getRect(row);
        final viewport = tester.getRect(list);
        expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.1));
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
      }

      expect(position.pixels, 0);
      // 连续向下会遇到部分可见和完全不可见的两种候选。
      for (var i = 1; i < 13; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expectVisible(i == 12 ? '@staff' : '@user_$i');
      }
      expect(position.pixels, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expectVisible('@user_0');
      expect(position.pixels, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expectVisible('@staff');
      for (var i = 11; i >= 0; i--) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expectVisible('@user_$i');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text, '@user_0 ');
      expect(list, findsNothing);

      await tester.enterText(find.byType(TextField), '@s');
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // 关闭后的同一帧也可能收到紧接着的按键，快捷键尚未重建。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(list, findsNothing);
      // 关闭后方向键应交回输入框。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      controller.dispose();
    });
  }
}
