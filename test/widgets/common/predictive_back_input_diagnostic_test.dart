import 'package:common_ui/common_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 回归测试：模拟手势期间的路由移除，检查首页点击与后续手势。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final predictive in [true, false]) {
    for (final scenario in [
      'normal',
      'removeDuringDrag',
      'popDuringDrag',
      'removeDuringExit',
      'removeDuringCancel',
    ]) {
      testWidgets('$scenario predictive=$predictive', (tester) async {
        final key = GlobalKey<NavigatorState>();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            theme: ThemeData(
              pageTransitionsTheme: PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: predictive
                      ? const PredictiveBackCupertinoPageTransitionsBuilder()
                      : const CupertinoPageTransitionsBuilder(),
                },
              ),
            ),
            home: Scaffold(
              body: TextButton(
                onPressed: () => taps++,
                child: const Text('tap home'),
              ),
            ),
          ),
        );
        final route = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail')),
        );
        key.currentState!.push(route);
        await tester.pumpAndSettle();
        Future<void> send(String method, [double? progress]) async {
          await binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                method,
                progress == null
                    ? null
                    : {
                        'touchOffset': <double>[20, 300],
                        'progress': progress,
                        'swipeEdge': 0,
                      },
              ),
            ),
            (_) {},
          );
        }

        await send('startBackGesture', 0);
        await send('updateBackGestureProgress', 0.4);
        await tester.pump();
        expect(key.currentState!.userGestureInProgress, predictive);
        if (scenario == 'removeDuringDrag' || scenario == 'popDuringDrag') {
          if (scenario == 'removeDuringDrag') {
            key.currentState!.removeRoute(route);
          } else {
            key.currentState!.pop();
          }
          await tester.pumpAndSettle();
          await send('commitBackGesture');
        } else {
          await send(
            scenario == 'removeDuringCancel'
                ? 'cancelBackGesture'
                : 'commitBackGesture',
          );
          if (scenario == 'removeDuringExit' ||
              scenario == 'removeDuringCancel') {
            key.currentState!.removeRoute(route);
          }
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('tap home'), warnIfMissed: false);
        await tester.pump();
        final stuck = key.currentState!.userGestureInProgress;
        final error = tester.takeException();
        expect(
          {
            'gestureStuck': stuck,
            'homeTaps': taps,
            'exception': error?.toString(),
          },
          {'gestureStuck': false, 'homeTaps': 1, 'exception': null},
        );

        // 再次返回须正常认领，检测重复释放导致的计数下溢。
        key.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('next detail')),
          ),
        );
        await tester.pumpAndSettle();
        await send('startBackGesture', 0);
        await tester.pump();
        expect(key.currentState!.userGestureInProgress, predictive);
        await send('updateBackGestureProgress', 0.3);
        await send('commitBackGesture');
        await tester.pumpAndSettle();
        expect(key.currentState!.userGestureInProgress, isFalse);
        await tester.tap(find.text('tap home'));
        expect(taps, 2);
      }, variant: const TargetPlatformVariant({TargetPlatform.android}));
    }
  }

  // 部分机型在同一次按压内重发 startBackGesture,前一轮既不 commit 也不
  // cancel(实录:拖出后进度瞬间回 0,右缘箭头重现再拖出提交)。
  // 重发的 start 若再计一次 didStartUserGesture,收尾只释放一次,计数
  // 永久卡在 1 → 所有路由 IgnorePointer → 全局点击失效。
  for (final restart in ['afterReturnToEdge', 'midDrag']) {
    for (final ending in ['commitBackGesture', 'cancelBackGesture']) {
      testWidgets('restart $restart then $ending', (tester) async {
        final key = GlobalKey<NavigatorState>();
        var homeTaps = 0;
        var detailTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            theme: ThemeData(
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android:
                      PredictiveBackCupertinoPageTransitionsBuilder(),
                },
              ),
            ),
            home: Scaffold(
              body: TextButton(
                onPressed: () => homeTaps++,
                child: const Text('tap home'),
              ),
            ),
          ),
        );
        final route = MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: TextButton(
              onPressed: () => detailTaps++,
              child: const Text('tap detail'),
            ),
          ),
        );
        key.currentState!.push(route);
        await tester.pumpAndSettle();
        Future<void> send(String method, [double? progress]) async {
          await binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                method,
                progress == null
                    ? null
                    : {
                        'touchOffset': <double>[380, 300],
                        'progress': progress,
                        'swipeEdge': 1,
                      },
              ),
            ),
            (_) {},
          );
        }

        await send('startBackGesture', 0);
        await send('updateBackGestureProgress', 0.4);
        await tester.pump();
        if (restart == 'afterReturnToEdge') {
          await send('updateBackGestureProgress', 0);
          await tester.pump();
        }
        await send('startBackGesture', 0);
        await send('updateBackGestureProgress', 0.5);
        await tester.pump();
        expect(route.animation!.value, closeTo(0.5, 0.001));
        await send(ending);
        await tester.pumpAndSettle();

        expect(key.currentState!.userGestureInProgress, isFalse);
        if (ending == 'commitBackGesture') {
          expect(route.isActive, isFalse);
          await tester.tap(find.text('tap home'));
          expect(homeTaps, 1);
        } else {
          expect(route.isCurrent, isTrue);
          expect(route.animation!.value, 1.0);
          await tester.tap(find.text('tap detail'));
          expect(detailTaps, 1);
          // 后续手势须正常认领并退出
          await send('startBackGesture', 0);
          await send('updateBackGestureProgress', 0.3);
          await send('commitBackGesture');
          await tester.pumpAndSettle();
          expect(key.currentState!.userGestureInProgress, isFalse);
          await tester.tap(find.text('tap home'));
          expect(homeTaps, 1);
        }
        expect(tester.takeException(), isNull);
      }, variant: const TargetPlatformVariant({TargetPlatform.android}));
    }
  }
}
