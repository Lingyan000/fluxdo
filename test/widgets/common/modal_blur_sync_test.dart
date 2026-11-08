import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final enabled in [false, true]) {
    for (final dialog in [false, true]) {
      testWidgets('模糊同步遵循偏好且持续到退出动画结束：开关=$enabled，弹窗=$dialog', (tester) async {
        SharedPreferences.setMockInitialValues({'pref_dialog_blur': enabled});
        final prefs = await SharedPreferences.getInstance();
        final nav = GlobalKey<NavigatorState>();
        final values = <double>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              navigatorKey: nav,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      if (dialog) {
                        showAppDialog<void>(
                          context: context,
                          onBlurSigmaChanged: values.add,
                          builder: (_) =>
                              const Dialog(child: SizedBox(height: 100)),
                        );
                      } else {
                        showAppBottomSheet<void>(
                          context: context,
                          onBlurSigmaChanged: values.add,
                          builder: (_) => const SizedBox(height: 200),
                        );
                      }
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final maximum = dialog ? 25.0 : 18.0;
        if (enabled) expect(values.last, inExclusiveRange(0, maximum));
        await tester.pumpAndSettle();
        expect(values.last, enabled ? maximum : 0);
        nav.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        if (enabled) expect(values.last, inExclusiveRange(0, maximum));
        await tester.pumpAndSettle();
        expect(values.last, 0);
        if (!enabled) expect(values.every((value) => value == 0), isTrue);
        expect(tester.takeException(), isNull);
      });

      testWidgets('晚到画面不阻塞弹层且就绪后统一渐入：开关=$enabled，弹窗=$dialog', (tester) async {
        SharedPreferences.setMockInitialValues({'pref_dialog_blur': enabled});
        final prefs = await SharedPreferences.getInstance();
        final nav = GlobalKey<NavigatorState>();
        final ready = ValueNotifier(false);
        final values = <double>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              navigatorKey: nav,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      if (dialog) {
                        showAppDialog<void>(
                          context: context,
                          blurReady: ready,
                          onBlurSigmaChanged: values.add,
                          builder: (_) => const Dialog(child: Text('内容')),
                        );
                      } else {
                        showAppBottomSheet<void>(
                          context: context,
                          blurReady: ready,
                          onBlurSigmaChanged: values.add,
                          builder: (_) =>
                              const SizedBox(height: 200, child: Text('内容')),
                        );
                      }
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pump();
        expect(find.text('内容'), findsOneWidget, reason: '画面尚未取到，菜单已可见');
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          values.last,
          enabled ? (dialog ? 25 : 18) : 0,
          reason: '路由生命周期与实际模糊就绪独立，等待画面时也持有使用权',
        );
        ready.value = true;
        await tester.pump();
        expect(find.byType(BackdropFilter), findsNothing, reason: '从零渐入');
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          find.byType(BackdropFilter),
          enabled ? findsOneWidget : findsNothing,
        );
        await tester.pumpAndSettle();
        // 遮罩没有截获弹层关闭，退场仍将使用权归零。
        nav.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        if (enabled) expect(values.last, greaterThan(0));
        await tester.pumpAndSettle();
        expect(values.last, 0);
        expect(find.byType(BackdropFilter), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        ready.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
