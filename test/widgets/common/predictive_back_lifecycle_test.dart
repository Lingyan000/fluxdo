import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:common_ui/common_ui.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lock during commit exit animation does not corrupt gesture count', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android:
                  PredictiveBackCupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('next page')),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Future<void> send(String method, [Map<String, Object?>? args]) {
      return binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    await send('startBackGesture', {
      'touchOffset': <double>[0, 300],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await send('updateBackGestureProgress', {
      'touchOffset': <double>[100, 300],
      'progress': 0.4,
      'swipeEdge': 0,
    });
    await tester.pump();

    // commit → pop 已发生,退场动画进行中
    await send('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 退场动画中途锁屏
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);

    // 回前台后:push 新页再做一次预测返回,必须仍有人认领
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await send('startBackGesture', {
      'touchOffset': <double>[0, 300],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(navigatorKey.currentState!.userGestureInProgress, isTrue,
        reason: '回前台后的新手势必须被认领');
    await send('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('next page'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
