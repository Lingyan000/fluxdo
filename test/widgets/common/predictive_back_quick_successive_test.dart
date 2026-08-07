import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

/// 差异点 8:连划场景。上一次 pop 退场动画未播完时快速再划,
/// popGestureEnabled 因 !animation.isCompleted 全员拒绝 → 引擎
/// fallback 整树缩小露黑边。栈顶 detector 必须静默认领,commit 后
/// 排队再退一层(连划 = 连续返回)。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> sendGesture(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  testWidgets(
    'quick successive back during exit transition is claimed and pops again',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
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
                    builder: (innerContext) => Scaffold(
                      body: TextButton(
                        onPressed: () =>
                            Navigator.of(innerContext).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const Scaffold(body: Text('page C')),
                              ),
                            ),
                        child: const Text('page B'),
                      ),
                    ),
                  ),
                ),
                child: const Text('page A'),
              ),
            ),
          ),
        ),
      );

      // 进到 C(栈:A/B/C)
      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('page B'));
      await tester.pumpAndSettle();
      expect(find.text('page C'), findsOneWidget);

      // 第一划:C 正常认领并 commit,退场动画开始
      await sendGesture('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('commitBackGesture');
      await tester.pump();
      // 退场动画中途(约半程)
      await tester.pump(const Duration(milliseconds: 150));

      // 第二划:B 是 current 但动画未完成——必须被静默认领
      // (认领失败 = binding 返回 false = 真机上引擎 fallback 黑边)
      bool claimed = false;
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('startBackGesture', {
            'touchOffset': <double>[0, 300],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        (ByteData? reply) {
          if (reply != null) {
            final decoded =
                const StandardMethodCodec().decodeEnvelope(reply);
            claimed = decoded == true;
          }
        },
      );
      await tester.pump();
      expect(claimed, isTrue, reason: '转场期第二划必须被认领,防引擎黑边');

      // commit → 排队 maybePop,B 也退掉,落回 A
      await sendGesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('page C'), findsNothing);
      expect(find.text('page B'), findsNothing);
      expect(find.text('page A'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'cancelled silent claim leaves the stack untouched',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
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
                    builder: (innerContext) => Scaffold(
                      body: TextButton(
                        onPressed: () =>
                            Navigator.of(innerContext).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const Scaffold(body: Text('page C')),
                              ),
                            ),
                        child: const Text('page B'),
                      ),
                    ),
                  ),
                ),
                child: const Text('page A'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('page A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('page B'));
      await tester.pumpAndSettle();

      await sendGesture('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // 第二划开始后取消:B 不应被退掉
      await sendGesture('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('cancelBackGesture');
      await tester.pumpAndSettle();

      expect(find.text('page C'), findsNothing);
      expect(find.text('page B'), findsOneWidget);

      // 取消后的下一划(B 已稳定)走正常认领,能退回 A
      await sendGesture('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('page A'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
