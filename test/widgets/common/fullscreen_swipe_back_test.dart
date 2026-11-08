import 'package:common_ui/common_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/fullscreen_swipe_back.dart';

void main() {
  Future<(GlobalKey<NavigatorState>, MaterialPageRoute<void>)> openPage(
    WidgetTester tester, {
    ValueNotifier<bool>? canPop,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          platform: defaultTargetPlatform,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.iOS: FullscreenSwipeBackTransitionsBuilder(
                CupertinoPageTransitionsBuilder(),
              ),
              TargetPlatform.android: FullscreenSwipeBackTransitionsBuilder(
                PredictiveBackCupertinoPageTransitionsBuilder(),
              ),
            },
          ),
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) {
        const page = Scaffold(body: SizedBox.expand(child: Text('detail')));
        if (canPop == null) return page;
        return ValueListenableBuilder<bool>(
          valueListenable: canPop,
          builder: (_, allowed, child) =>
              PopScope(canPop: allowed, child: child!),
          child: page,
        );
      },
    );
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    return (navigator, route);
  }

  Future<void> startReturning(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(250, 300));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  testWidgets(
    '返回回弹时再次按住停在当前位置，继续拖动不中断手势计数',
    (tester) async {
      final (navigator, route) = await openPage(tester);
      await startReturning(tester);
      expect(route.animation!.value, lessThan(1));
      final before = route.animation!.value;
      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 50));
      expect(route.animation!.value, closeTo(before, 0.001));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(route.animation!.value, lessThan(before - 0.05));
      expect(navigator.currentState!.userGestureInProgress, isTrue);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(route.animation!.value, 1);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(find.text('detail'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('拖过半屏收到 cancel 仍回到当前页', (tester) async {
    final (navigator, route) = await openPage(tester);
    final gesture = await tester.startGesture(const Offset(100, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(470, 0));
    await tester.pump();
    expect(route.animation!.value, lessThan(0.5));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
  });

  testWidgets('回弹期间 PopScope 禁止返回后不接受新的返回拖动', (tester) async {
    final canPop = ValueNotifier(true);
    addTearDown(canPop.dispose);
    final (navigator, route) = await openPage(tester, canPop: canPop);
    await startReturning(tester);
    canPop.value = false;
    await tester.pump();
    final before = route.animation!.value;
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 50));
    expect(route.animation!.value, greaterThan(before));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
  });

  testWidgets('反复接管回弹后仍可提交返回，手势计数归零', (tester) async {
    final (navigator, route) = await openPage(tester);
    await startReturning(tester);
    for (var i = 0; i < 3; i++) {
      final before = route.animation!.value;
      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 20));
      expect(route.animation!.value, closeTo(before, 0.001));
      await gesture.moveBy(const Offset(25, 0));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(25, 0));
    await gesture.moveBy(const Offset(450, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('detail'), findsNothing);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
  });

  testWidgets('回弹时轻点或取消按压都继续回弹，不遗留暂停状态', (tester) async {
    final (navigator, route) = await openPage(tester);
    for (final cancel in [false, true]) {
      await startReturning(tester);
      final gesture = await tester.startGesture(const Offset(400, 300));
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(route.animation!.value, 1);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
    }
  });

  testWidgets('回弹期间程序化退出不会重复释放手势计数', (tester) async {
    final (navigator, _) = await openPage(tester);
    await startReturning(tester);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动期间路由被移除后释放手势计数', (tester) async {
    final (navigator, route) = await openPage(tester);
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(navigator.currentState!.userGestureInProgress, isTrue);
    navigator.currentState!.removeRoute(route);
    await tester.pumpAndSettle();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    expect(tester.takeException(), isNull);
  });
}
