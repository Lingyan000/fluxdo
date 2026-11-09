import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_panel_motion.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_panel_shell.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/utils/platform_utils.dart';

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets('弹窗慢拉收起、内容滚动和手势禁用（减少动画=$reduceMotion）', (tester) async {
      PlatformUtils.debugDesktopOverride = false;
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var allowed = true, minimized = 0, taps = 0;
      late MiniAppPanelMotion motion;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [RouteInteractionObserver()],
          home: Scaffold(
            body: TextButton(
              onPressed: () {
                motion = MiniAppPanelMotion(
                  nav.currentState!,
                  null,
                  BrowserTabSession(url: 'https://mini-app.test'),
                  reduceMotion: reduceMotion,
                )..canDrag = () => allowed;
                motion.onReturnToDock = () {
                  minimized++;
                  motion.minimize();
                  nav.currentState!.pop();
                };
                showAppBottomSheet<void>(
                  context: nav.currentContext!,
                  blur: false,
                  enableDrag: false,
                  isScrollControlled: true,
                  transitionAnimationController: motion.controller,
                  onDisposed: motion.dispose,
                  sheetAnimationStyle: const AnimationStyle(
                    curve: Curves.linear,
                    reverseCurve: Curves.linear,
                  ),
                  builder: (_) => MiniAppPanelShell(
                    motion: motion,
                    onHeightChanged: motion.updateExtent,
                    builder: (_) => Column(
                      children: [
                        SizedBox(
                          height: 56,
                          child: TextButton(
                            onPressed: () => taps++,
                            child: const Text('顶栏按钮'),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: scroll,
                            itemCount: 60,
                            itemExtent: 60,
                            itemBuilder: (_, index) => Text('内容 $index'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ).then((_) => motion.didPop());
                motion.start(fromDock: false);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final panel = find.byType(MiniAppPanelShell);
      final origin = tester.getTopLeft(panel);
      expect(motion.moving.value, isFalse);
      await tester.tap(find.text('顶栏按钮'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(nav.currentState!.userGestureInProgress, isFalse);
      expect(motion.moving.value, isFalse);
      allowed = false;
      await tester.dragFrom(
        origin + const Offset(180, 12),
        const Offset(0, 250),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(panel), origin);
      expect(minimized, 0);
      allowed = true;
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(tester.getTopLeft(panel), origin);
      // 足够距离但没有甩动速度，仍按位置收起。
      final drag = await tester.startGesture(origin + const Offset(180, 12));
      await drag.moveBy(const Offset(0, 24));
      await tester.pump();
      await drag.moveBy(const Offset(0, 250));
      await tester.pump(const Duration(milliseconds: 500));
      await drag.up();
      await tester.pumpAndSettle();
      expect(minimized, 1);
      expect(panel, findsNothing);
      expect(nav.currentState!.userGestureInProgress, isFalse);
      // push 后还没有首帧就关闭，同样释放外部 controller。
      await tester.tap(find.text('打开'));
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
