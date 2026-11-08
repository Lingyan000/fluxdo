import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/widgets/browser/browser_page_route.dart';

void main() {
  testWidgets('浏览器普通进入、关闭与应用导航一致，底栏恢复后关闭仍沿用普通导航', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    const pageKey = ValueKey('destination');
    const backgroundKey = ValueKey('background');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android:
                  PredictiveBackCupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: const Scaffold(key: backgroundKey),
      ),
    );
    Widget page(BuildContext _) => const Scaffold(key: pageKey);
    final normal = MaterialPageRoute<void>(builder: page);
    navigator.currentState!.push(normal);
    final normalDuration = normal.transitionDuration;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final normalEnter = tester.getRect(find.byKey(pageKey));
    final normalBackground = tester.getRect(
      find.byKey(backgroundKey, skipOffstage: false),
    );
    expect(normalEnter.left, inExclusiveRange(0, 390));
    expect(normalEnter.top, 0);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final normalExit = tester.getRect(find.byKey(pageKey));
    await tester.pumpAndSettle();

    final browser = BrowserPageRoute<void>(builder: page);
    navigator.currentState!.push(browser);
    expect(browser.transitionDuration, normalDuration);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(find.byKey(pageKey)), normalEnter);
    expect(
      tester.getRect(find.byKey(backgroundKey, skipOffstage: false)),
      normalBackground,
    );
    await tester.pumpAndSettle();
    // 恢复完成后取消预测返回，必须继续水平回弹，不能重新进入底栏展开动画。
    Future<void> sendBack(String method, [double? progress]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              method,
              progress == null
                  ? null
                  : {
                      'touchOffset': <double>[10, 300],
                      'progress': progress,
                      'swipeEdge': 0,
                    },
            ),
          ),
          (_) {},
        );
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(find.byKey(pageKey)), normalExit);
    await tester.pumpAndSettle();

    navigator.currentState!.push(
      BrowserPageRoute<void>(builder: page, fromDock: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester.getRect(find.byKey(backgroundKey, skipOffstage: false)),
      const Rect.fromLTWH(0, 0, 390, 844),
    );
    final expanding = tester.getRect(find.byKey(pageKey));
    expect(expanding.top, inExclusiveRange(0, 844));
    expect(expanding.left, 0);
    expect(expanding.width, closeTo(390, .001));
    expect(expanding.height, closeTo(844, .001));
    await tester.pumpAndSettle();
    await sendBack('startBackGesture', 0);
    await sendBack('updateBackGestureProgress', .5);
    await tester.pump();
    expect(tester.getRect(find.byKey(pageKey)).left, greaterThan(0));
    await sendBack('cancelBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final cancelling = tester.getRect(find.byKey(pageKey));
    expect(cancelling.top, 0);
    expect(cancelling.left, greaterThan(0));
    expect(cancelling.size, const Size(390, 844));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(pageKey)).left, 0);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(find.byKey(pageKey)), normalExit);
    await tester.pumpAndSettle();
    // 截图失败的收起也要向下退出，不能原地消失或改成横向关闭。
    final withoutPreview = BrowserPageRoute<void>(builder: page);
    navigator.currentState!.push(withoutPreview);
    await tester.pumpAndSettle();
    final tab = BrowserTabSession(url: 'https://example.com');
    withoutPreview.beginMinimize(tab, hasSnapshot: false);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final shrinking = tester.getRect(find.byKey(pageKey));
    expect(shrinking.top, inExclusiveRange(0, 844));
    expect(shrinking.left, 0);
    expect(shrinking.width, closeTo(390, .001));
    expect(shrinking.height, closeTo(844, .001));
    expect(
      tester.getRect(find.byKey(backgroundKey, skipOffstage: false)),
      const Rect.fromLTWH(0, 0, 390, 844),
    );
    await tester.pumpAndSettle();
    await tab.close();
    expect(tester.takeException(), isNull);
  });
}
