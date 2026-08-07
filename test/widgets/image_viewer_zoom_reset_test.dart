import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

/// 复现图片查看器「放大后返回闪烁」的机制层测试:
/// 缩放是 RawGestureImage 画布级变换,Hero 飞行只收缩布局盒子,
/// 飞行中拿全屏布局的缩放裁切往小盒子里画 → 闪烁。修法是退场
/// (路由 reverse / 预测返回手势置位)瞬间把 controller 归位。
/// 这里不拉起完整查看器(依赖网络图),直接验证两路钩子的触发时机:
/// 同结构的 controller + 路由监听在 pop/手势时 totalScale 必须回 1。
class _ZoomResetHarness extends StatefulWidget {
  const _ZoomResetHarness({required this.controller});
  final ImageGestureController controller;

  @override
  State<_ZoomResetHarness> createState() => _ZoomResetHarnessState();
}

class _ZoomResetHarnessState extends State<_ZoomResetHarness> {
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onStatus);
    }
    _route?.navigator?.userGestureInProgressNotifier.addListener(_onGesture);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) widget.controller.reset();
  }

  void _onGesture() {
    final nav = _route?.navigator;
    if (nav != null &&
        nav.userGestureInProgress &&
        (_route?.isCurrent ?? false)) {
      widget.controller.reset();
    }
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onStatus);
    _route?.navigator?.userGestureInProgressNotifier
        .removeListener(_onGesture);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpViewer(
    WidgetTester tester,
    ImageGestureController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                PageRouteBuilder<void>(
                  opaque: false,
                  pageBuilder: (_, _, _) =>
                      _ZoomResetHarness(controller: controller),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) =>
                          buildPredictiveBackPageTransitions(
                            context,
                            animation,
                            secondaryAnimation,
                            child,
                            useSharedElementPreview: false,
                            fallbackBuilder: (_, animation, _, child) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                          ),
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
  }

  void zoomTo(ImageGestureController controller, double scale) {
    controller.details = GestureDetails(
      totalScale: scale,
      offset: Offset.zero,
      gestureDetails: controller.details,
    );
  }

  testWidgets('程序化 pop:reverse 首帧缩放归位', (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 3.0);
    expect(controller.details!.totalScale, 3.0);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    // reverse 状态派发在 pop 同帧,归位应已发生
    expect(controller.details!.totalScale, 1.0);
    await tester.pumpAndSettle();
  });

  testWidgets('预测返回手势置位即缩放归位', (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 2.5);
    expect(controller.details!.totalScale, 2.5);

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('startBackGesture', {
          'touchOffset': <double>[0, 300],
          'progress': 0.0,
          'swipeEdge': 0,
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(controller.details!.totalScale, 1.0);

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('commitBackGesture'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
