import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:common_ui/common_ui.dart';

/// Hero 路由 × 预测返回:路由认领手势是 Hero 跟手飞行的前提
/// (HeroController 只为 user gesture 转场启动带 transitionOnUserGestures
/// 的飞行,不认领则 Hero 完全不飞);视觉由调用方自己的 transitionBuilder
/// 决定(方案 A 单一分支)。两端 Hero 均带 transitionOnUserGestures。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> sendGesture(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Widget buildApp({
    required GlobalKey<NavigatorState> navigatorKey,
    required void Function() onFlight,
  }) {
    Widget buildHero(double size) {
      return Hero(
        tag: 'image',
        transitionOnUserGestures: true,
        flightShuttleBuilder: (_, _, _, _, _) {
          onFlight();
          return ColoredBox(
            color: Colors.red,
            child: SizedBox.square(dimension: size),
          );
        },
        child: ColoredBox(
          color: Colors.red,
          child: SizedBox.square(dimension: size),
        ),
      );
    }

    return MaterialApp(
      navigatorKey: navigatorKey,
      // 显式用本仓库 builder:框架默认 Android 主题(官方
      // PredictiveBackPageTransitionsBuilder)内部有同名私有转场类,
      // 会被下方 runtimeType 字符串断言误中
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
          builder: (context) => Column(
            children: [
              buildHero(48),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      opaque: false,
                      pageBuilder: (_, _, _) => Scaffold(
                        backgroundColor: Colors.black,
                        body: Center(child: buildHero(240)),
                      ),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                            return buildPredictiveBackPageTransitions(
                              context,
                              animation,
                              secondaryAnimation,
                              child,
                              transitionBuilder: (_, animation, _, child) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                            );
                          },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets(
    'predictive back gesture drives the paired hero flight',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      var heroFlights = 0;

      await tester.pumpWidget(
        buildApp(navigatorKey: navigatorKey, onFlight: () => heroFlights++),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      heroFlights = 0;

      await sendGesture('startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();

      // 路由已认领手势(认领是 Hero 跟手飞行的前提)
      expect(navigatorKey.currentState!.userGestureInProgress, isTrue);

      await sendGesture('updateBackGestureProgress', {
        'touchOffset': <double>[80, 300],
        'progress': 0.3,
        'swipeEdge': 0,
      });
      await tester.pump();

      // 手势期间 Hero 已跟手起飞;视觉走 fallback,不套缩放预览
      expect(heroFlights, greaterThan(0));

      await sendGesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'cancelled predictive back restores the pushed route',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        buildApp(navigatorKey: navigatorKey, onFlight: () {}),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await sendGesture('startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('updateBackGestureProgress', {
        'touchOffset': <double>[80, 300],
        'progress': 0.4,
        'swipeEdge': 0,
      });
      await tester.pump();

      await sendGesture('cancelBackGesture');
      await tester.pumpAndSettle();

      // 取消后查看器仍在,Hero 归位不残留
      expect(find.byType(Scaffold), findsWidgets);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
      expect(navigatorKey.currentState!.canPop(), isTrue);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
