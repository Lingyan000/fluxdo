import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';

void main() {
  testWidgets('普通打开浏览器在首帧前隐藏底栏，返回后恢复', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final observer = BrowserDockObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const Scaffold(),
      ),
    );
    expect(observer.hidden.value, isFalse);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: browserPageRouteName),
        builder: (_) => const Scaffold(),
      ),
    );
    // 不先 pump：进入的第一帧布局必须已收到隐藏通知。
    expect(observer.hidden.value, isTrue);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(observer.hidden.value, isFalse);
  });

  testWidgets('小程序保留原有帧末通知时序', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final observer = BrowserDockObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const Scaffold(),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: miniAppPageRouteName),
        builder: (_) => const Scaffold(),
      ),
    );
    expect(observer.hidden.value, isFalse);
    await tester.pump();
    expect(observer.hidden.value, isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
