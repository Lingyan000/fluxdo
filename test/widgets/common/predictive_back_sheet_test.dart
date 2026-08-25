import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:common_ui/common_ui.dart';

/// 底部弹框的 Android 预测返回(差异点 8)。
///
/// 预测返回**不是 PageRoute 专属能力**:`PredictiveBackRoute` 的实现体在
/// `TransitionRoute`(routes.dart:111 `implements PredictiveBackRoute`),
/// 而 `ModalBottomSheetRoute → PopupRoute → ModalRoute → TransitionRoute`
/// 与 `PageRoute → ModalRoute → TransitionRoute` 共享同一父类 —— 四个
/// handler 与 `popGestureEnabled` 全都继承得到。上游把探测器的 route 写成
/// `PageRoute` 只因 `PageTransitionsBuilder.buildTransitions` 的签名只喂
/// `PageRoute<T>`,那是入口的限制而非能力的限制。
///
/// 视觉上不新增任何动画:sheet 位移本就绑 `route.animation`
/// (`_ModalBottomSheetState` 里 `_sheetAnimation.parent = route.animation`),
/// 官方的手指下拉关闭改的是同一个 controller 的 value,所以手势进度天然
/// 驱动 sheet 跟手下滑,与下拉关闭同一套动画。
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

  /// 三键返回键:touchOffset 为空 ⇒ isButtonEvent,不该被当成手势认领
  Map<String, Object?> buttonArgs() => {
    'touchOffset': null,
    'progress': 0.0,
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

  /// 打开一个走统一入口的底部弹框(即全 app 共用的
  /// `_BlurModalBottomSheetRoute`)。blur 关掉以免引入 BackdropFilter。
  Future<void> openSheet(WidgetTester tester, BuildContext context) async {
    showAppBottomSheet<void>(
      context: context,
      blur: false,
      builder: (_) => const SizedBox(
        height: 300,
        child: Center(child: Text('sheet 内容')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// sheet 的纵向位置 —— 跟手下滑的观测量
  double sheetTop(WidgetTester tester) =>
      tester.getTopLeft(find.text('sheet 内容', skipOffstage: false)).dy;

  ModalRoute<dynamic> sheetRoute(WidgetTester tester) =>
      ModalRoute.of(tester.element(find.text('sheet 内容')))!;

  testWidgets(
    '手势进度驱动 sheet 跟手下滑(单调,且 commit 后关闭)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await openSheet(tester, navigatorKey.currentContext!);

      final route = sheetRoute(tester);
      // 前提:sheet 不是 PageRoute,但必须满足认领条件
      expect(route, isNot(isA<PageRoute<dynamic>>()));
      expect(route, isA<PopupRoute<dynamic>>());
      expect(
        route.popGestureEnabled,
        isTrue,
        reason: 'popGestureEnabled 为 false ⇒ 探测器不会认领,功能不可能生效',
      );

      final double atRest = sheetTop(tester);

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      expect(
        navigatorKey.currentState!.userGestureInProgress,
        isTrue,
        reason: 'sheet 未认领手势(类型闸门仍在拦 PopupRoute?)',
      );

      // 逐段喂进度:sheet 必须单调下滑
      double prev = atRest;
      for (final p in [0.2, 0.5, 0.8]) {
        await send('updateBackGestureProgress', gestureArgs(p));
        await tester.pump();
        final now = sheetTop(tester);
        expect(
          now,
          greaterThan(prev),
          reason: '进度 $p 未让 sheet 继续下滑(top $prev → $now)= 没跟手',
        );
        prev = now;
      }
      expect(
        prev - atRest,
        greaterThan(20.0),
        reason: '总位移过小,不像跟手下滑',
      );

      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('sheet 内容'), findsNothing);
      expect(find.text('page B'), findsOneWidget, reason: '只该关 sheet');
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'cancel:sheet 弹回原位,手势计数归零',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await openSheet(tester, navigatorKey.currentContext!);

      final double atRest = sheetTop(tester);

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.4));
      await tester.pump();
      expect(sheetTop(tester), greaterThan(atRest));

      await send('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(sheetTop(tester), atRest, reason: 'cancel 应弹回原位');
      expect(find.text('sheet 内容'), findsOneWidget);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '互斥性:sheet 在栈顶时,下层页面不得同时被关闭',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      final pageRoute =
          ModalRoute.of(tester.element(find.text('page B')))!;
      await openSheet(tester, navigatorKey.currentContext!);

      // binding 的 _handleStartBackGesture 会询问**所有** observer 并收集
      // 全部返回 true 的(不是先到先得),互斥全靠各自的 isCurrent 判据。
      expect(
        pageRoute.isCurrent,
        isFalse,
        reason: 'sheet 在栈顶时下层 route 必须 !isCurrent,否则会双认领',
      );

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.5));
      await tester.pump();
      // 下层页面不该被手势平移(那是 Cupertino 转场的表现)
      expect(
        tester.getTopLeft(find.text('page B', skipOffstage: false)).dx,
        0.0,
        reason: '下层页面被同一手势驱动 = 双认领,一次手势关两层',
      );

      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('sheet 内容'), findsNothing);
      expect(
        find.text('page B'),
        findsOneWidget,
        reason: '一次手势不能既关 sheet 又关页面',
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'commit 后 sheet 退场进度单调递减,不回跳(差异点 7 对 sheet 同样生效)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await openSheet(tester, navigatorKey.currentContext!);

      final route = sheetRoute(tester);

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.4));
      await tester.pump();
      final double atRelease = route.animation!.value;
      expect(atRelease, closeTo(0.6, 0.01));

      await send('commitBackGesture');
      await tester.pump();

      final samples = <double>[route.animation!.value];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final v = route.animation?.value;
        if (v == null) break;
        samples.add(v);
        if (v == 0.0) break;
      }

      final double peak = samples.reduce((a, b) => a > b ? a : b);
      expect(
        peak,
        lessThanOrEqualTo(atRelease + 0.01),
        reason: '出现高于松手进度的帧 = 被拽回 1.0 重播;序列=$samples',
      );
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i],
          lessThanOrEqualTo(samples[i - 1] + 0.001),
          reason: '第 $i 帧进度回升 = 重播;序列=$samples',
        );
      }

      await tester.pumpAndSettle();
      expect(find.text('sheet 内容'), findsNothing);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '三键返回键(isButtonEvent)不被当成手势认领',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await openSheet(tester, navigatorKey.currentContext!);

      await send('startBackGesture', buttonArgs());
      await tester.pump();
      expect(
        navigatorKey.currentState!.userGestureInProgress,
        isFalse,
        reason: '按键事件被当成跟手手势 = 会出现无进度的假跟手',
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'PopScope 否决时手势不认领(表情面板开启等场景)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      // 与 reply_sheet.dart 的 PopScope(canPop: !_showEmojiPanel) 同构:
      // 返回应先关内部面板,而不是关整个 sheet ⇒ 手势必须被否决
      showAppBottomSheet<void>(
        context: navigatorKey.currentContext!,
        blur: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: SizedBox(
            height: 300,
            child: Center(child: Text('sheet 内容')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        sheetRoute(tester).popGestureEnabled,
        isFalse,
        reason: 'PopScope(canPop:false) 必须否决跟手手势',
      );

      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      expect(
        navigatorKey.currentState!.userGestureInProgress,
        isFalse,
        reason: '被 PopScope 保护的 sheet 不该被跟手拖动',
      );
      expect(find.text('sheet 内容'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('非 Android 平台不挂探测器(零行为变化)', (tester) async {
    expect(
      wrapPredictiveBackForModalRoute(
        route: ModalBottomSheetRoute<void>(
          builder: (_) => const SizedBox.shrink(),
          isScrollControlled: false,
        ),
        child: const SizedBox(key: Key('inner')),
      ),
      isA<SizedBox>(),
      reason: '非 Android 应原样返回 child,不包任何 widget',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets(
    '统一入口产出的 route 才带探测器(裸用官方 API 不带)',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(buildApp(navigatorKey));
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();

      // 统一入口:_BlurModalBottomSheetRoute(私有类,按名字断言)
      await openSheet(tester, navigatorKey.currentContext!);
      expect(
        sheetRoute(tester).runtimeType.toString(),
        contains('BlurModalBottomSheetRoute'),
        reason:
            '统一入口应产出带探测器的 route。若这里变成 ModalBottomSheetRoute,'
            '说明调用点被改回裸用 showModalBottomSheet,预测返回会静默失效',
      );
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      // 裸用官方:没有探测器 —— 作为对照,证明上面那条断言有鉴别力
      showModalBottomSheet<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => const SizedBox(
          height: 300,
          child: Center(child: Text('sheet 内容')),
        ),
      );
      await tester.pumpAndSettle();
      final bare = sheetRoute(tester);
      expect(bare.runtimeType.toString(), 'ModalBottomSheetRoute<void>');

      final double atRest = sheetTop(tester);
      await send('startBackGesture', gestureArgs(0.0));
      await tester.pump();
      await send('updateBackGestureProgress', gestureArgs(0.5));
      await tester.pump();
      expect(
        sheetTop(tester),
        atRest,
        reason: '裸用官方 API 的 sheet 无探测器,不该跟手 —— 对照组',
      );
      await send('cancelBackGesture');
      await tester.pumpAndSettle();
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
