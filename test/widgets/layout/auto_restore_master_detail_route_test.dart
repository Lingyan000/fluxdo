import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/auto_restore_master_detail_route.dart';

void main() {
  testWidgets('窗口恢复宽屏后移除临时全屏路由', (tester) async {
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

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const AutoRestoreMasterDetailRoute(
          child: Scaffold(body: Text('临时全屏资料页')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('临时全屏资料页'), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    expect(find.text('临时全屏资料页'), findsNothing);
    expect(find.text('平行视界主页'), findsOneWidget);
  });
}
