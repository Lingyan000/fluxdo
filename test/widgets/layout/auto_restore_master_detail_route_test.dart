import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/auto_restore_master_detail_route.dart';

void main() {
  testWidgets('窗口恢复宽屏后移除话题与资料临时路由', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('平行视界主页')),
      ),
    );

    final topicRoute = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('临时全屏话题页')),
    );
    navigatorKey.currentState!.push(topicRoute);
    await tester.pumpAndSettle();

    var restoreCount = 0;
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => AutoRestoreMasterDetailRoute(
          onRestore: () {
            restoreCount++;
            navigatorKey.currentState!.removeRoute(topicRoute);
          },
          child: const Scaffold(body: Text('临时全屏资料页')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('临时全屏资料页'), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    expect(find.text('临时全屏资料页'), findsNothing);
    expect(find.text('临时全屏话题页'), findsNothing);
    expect(find.text('平行视界主页'), findsOneWidget);
    expect(restoreCount, 1);
  });

  testWidgets('被上层页面覆盖时等待顶层页面返回后再恢复', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('平行视界主页')),
      ),
    );

    var restoreCount = 0;
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => AutoRestoreMasterDetailRoute(
          onRestore: () => restoreCount++,
          child: const Scaffold(body: Text('被覆盖的临时页')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('顶层页面')),
      ),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    expect(find.text('顶层页面'), findsOneWidget);
    expect(restoreCount, 0);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.text('被覆盖的临时页'), findsNothing);
    expect(find.text('平行视界主页'), findsOneWidget);
    expect(restoreCount, 1);
  });
}
