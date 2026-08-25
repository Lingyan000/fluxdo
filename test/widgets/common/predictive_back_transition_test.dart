import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:common_ui/common_ui.dart';

/// 方案 A 的核心保证:**同一页面在任何返回路径下动画一致**。
///
/// 官方实现按「系统这次有没有发 startBackGesture」在 shared-element
/// 预览与 FadeForwards 之间二选一,导致同一页面时而缩放退出、时而滑动
/// 退出(三键返回键、被判成点击的快扫、注册态不对时系统只发 popRoute)。
/// 本文件断言:预测返回手势 / 程序化 pop 两条路径落到同一套 Cupertino
/// 转场,且手势进度确实驱动路由动画。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> send(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Map<String, Object?> gestureArgs(double progress) => {
    'touchOffset': <double>[10, 300],
    'progress': progress,
    'swipeEdge': 0,
  };

  Widget buildApp(GlobalKey<NavigatorState> navigatorKey) {
    return MaterialApp(
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
                builder: (_) => const Scaffold(body: Text('page B')),
              ),
            ),
            child: const Text('page A'),
          ),
        ),
      ),
    );
  }

  /// 退场中途 page B 的横向位移(Cupertino 平移的观测量)
  double bOffsetX(WidgetTester tester) =>
      tester.getTopLeft(find.text('page B', skipOffstage: false)).dx;

  testWidgets(
    '预测返回手势与程序化 pop 走同一套 Cupertino 转场(单分支一致)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      // —— 路径 1:系统预测返回手势 ——
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.5));
      await tester.pump();
      // 手势进度必须驱动路由动画 → 页面已右移(Cupertino 跟手)
      expect(bOffsetX(tester), greaterThan(0.0),
          reason: '手势期应由 Cupertino 平移跟手,而非缩放预览');
      // 且不存在 shared-element 预览(方案 A 已整段删除)
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString().contains('SharedElement'),
        ),
        findsNothing,
      );
      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);

      // —— 路径 2:程序化 pop(等价于按钮/三键返回) ——
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(bOffsetX(tester), greaterThan(0.0), reason: '程序化 pop 同为平移');

      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'cancel 后页面回到原位,手势态归零',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.4));
      await tester.pump();
      expect(bOffsetX(tester), greaterThan(0.0));

      await send('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(bOffsetX(tester), 0.0, reason: 'cancel 应回弹到原位');
      expect(find.text('page B'), findsOneWidget);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '手势中途锁屏:代打 cancel 归零手势态,回前台后仍可认领(差异点 4)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.4));
      await tester.pump();
      expect(navigatorKey.currentState!.userGestureInProgress, isTrue);

      // 系统不为被打断的手势补发 commit/cancel
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(navigatorKey.currentState!.userGestureInProgress, isFalse,
          reason: '代打 cancel 应把计数归零,否则预测返回永久失效');
      expect(find.text('page B'), findsOneWidget);

      // 回前台后的新手势必须仍能认领
      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      expect(navigatorKey.currentState!.userGestureInProgress, isTrue);
      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '陈旧 cancel(原生 onStop 无条件广播)不得毒化手势计数(差异点 5)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      // 一轮以 cancel 收尾:认领者与 route 都还活着
      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.3));
      await tester.pump();
      await send('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);

      // 锁屏:原生 onStop 无条件再广播一次 cancel,打到陈旧认领者
      await send('cancelBackGesture');
      await tester.pump();

      // 计数不得下溢:新手势仍能认领并 commit
      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      expect(navigatorKey.currentState!.userGestureInProgress, isTrue,
          reason: '陈旧 cancel 若打成负计数,此处将无人认领');
      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'commit 后退场进度单调递减,不回跳到 1.0(差异点 7:无重播)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      final route =
          ModalRoute.of(tester.element(find.text('page B')))!
              as PageRoute<dynamic>;

      // 拖到 0.4:退场进度 = 1 - 0.4 = 0.6
      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.4));
      await tester.pump();
      final double atRelease = route.animation!.value;
      expect(atRelease, closeTo(0.6, 0.01), reason: '手势进度应驱动路由动画');

      // commit:框架实现会在此把进度硬拽回 1.0 再重走(重播)
      await send('commitBackGesture');
      await tester.pump();

      // 逐帧采样整段退场
      final samples = <double>[route.animation!.value];
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final v = route.animation?.value;
        if (v == null) break;
        samples.add(v);
        if (v == 0.0) break;
      }

      // 关键断言 1:没有任何一帧高于松手进度(重播必产生 ~1.0 的帧)
      final double peak = samples.reduce((a, b) => a > b ? a : b);
      expect(
        peak,
        lessThanOrEqualTo(atRelease + 0.01),
        reason: '出现高于松手进度的帧 = 被拽回 1.0 重播;序列=$samples',
      );

      // 关键断言 2:全程单调不增
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i],
          lessThanOrEqualTo(samples[i - 1] + 0.001),
          reason: '第 $i 帧进度回升 = 重播;序列=$samples',
        );
      }

      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);
      expect(find.text('page B'), findsNothing);
      // 手势计数必须归零(自管 didStopUserGesture 的正确性)
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
