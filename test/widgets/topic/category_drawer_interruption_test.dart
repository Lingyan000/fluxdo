import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/topic/category_drawer.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

class _SignedOutUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

void main() {
  final binding = _Binding();

  Future<void> sendBack(String method, [double progress = 0]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, {
          'touchOffset': <double>[0, 400],
          'progress': progress,
          'swipeEdge': 0,
        }),
      ),
      (_) {},
    );
  }

  Future<(GlobalKey<ControlledCategoryDrawerState>, ScrollController)> pumpHome(
    WidgetTester tester, {
    VoidCallback? onTopicTap,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final drawer = GlobalKey<ControlledCategoryDrawerState>();
    final list = ScrollController(initialScrollOffset: 500);
    addTearDown(list.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          categoriesProvider.overrideWith((_) async => []),
          currentUserProvider.overrideWith(_SignedOutUser.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            scrollBehavior: const DesktopScrollInteractionBehavior(),
            home: Scaffold(
              body: Stack(
                children: [
                  ListView.builder(
                    controller: list,
                    itemExtent: 60,
                    itemCount: 100,
                    itemBuilder: (_, i) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTopicTap,
                      child: Text('topic $i'),
                    ),
                  ),
                  ControlledCategoryDrawer(
                    key: drawer,
                    onPinnedSelected: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Reproduce pulling the actual drawer out through the same entry point as
    // the home pager, then letting its spring finish opening.
    drawer.currentState!.dragBy(210);
    drawer.currentState!.settle(0);
    await tester.pumpAndSettle();
    expect(drawer.currentState!.isOpen, isTrue);
    return (drawer, list);
  }

  for (final delayMs in [0, 16, 80]) {
    for (final x in [150.0, 350.0]) {
      for (final dy in [-90.0, 90.0]) {
        testWidgets('关闭侧栏后立即竖滑列表 delay=$delayMs x=$x dy=$dy', (tester) async {
          final (drawer, list) = await pumpHome(tester);
          // Tap the scrim to close, then start the next gesture while the
          // panel is still on screen. At delay=0 no build/paint has run yet.
          await tester.tapAt(const Offset(350, 400));
          if (delayMs > 0) {
            await tester.pump();
            await tester.pump(Duration(milliseconds: delayMs));
          }
          expect(drawer.currentState!.isOpen, isTrue);
          final before = list.offset;
          final gesture = await tester.startGesture(Offset(x, 400));
          await gesture.moveBy(Offset(3, dy.sign * 30));
          await tester.pump();
          await gesture.moveBy(Offset(5, dy));
          await tester.pump();
          expect((list.offset - before) * -dy.sign, greaterThan(60));
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(drawer.currentState!.isOpen, isFalse);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('侧栏打开时仍拦住底层列表，关闭再重新拉出可接管弹簧', (tester) async {
    final (drawer, list) = await pumpHome(tester);
    final before = list.offset;
    await tester.dragFrom(const Offset(350, 400), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(list.offset, before);
    expect(drawer.currentState!.isOpen, isTrue);
    drawer.currentState!.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    drawer.currentState!.dragBy(200);
    drawer.currentState!.settle(500);
    await tester.pumpAndSettle();
    expect(drawer.currentState!.isOpen, isTrue);
    await tester.dragFrom(const Offset(350, 400), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(list.offset, before);
  });

  testWidgets('打开首帧前立刻关闭不会继续弹开', (tester) async {
    final (drawer, _) = await pumpHome(tester);
    drawer.currentState!.close();
    await tester.pumpAndSettle();
    drawer.currentState!.open();
    drawer.currentState!.close();
    await tester.pumpAndSettle();
    expect(drawer.currentState!.isOpen, isFalse);
  });

  testWidgets('向左拖动关闭后立刻竖滑交给列表', (tester) async {
    final (drawer, list) = await pumpHome(tester);
    final closing = await tester.startGesture(const Offset(350, 400));
    await closing.moveBy(const Offset(-30, 2));
    await tester.pump();
    await closing.moveBy(const Offset(-160, 8));
    await tester.pump();
    await closing.up();
    expect(drawer.currentState!.isOpen, isTrue);

    final before = list.offset;
    final scrolling = await tester.startGesture(const Offset(350, 400));
    await scrolling.moveBy(const Offset(3, -30));
    await tester.pump();
    await scrolling.moveBy(const Offset(4, -100));
    await tester.pump();
    expect(list.offset - before, greaterThan(60));
    await scrolling.cancel();
    await tester.pumpAndSettle();
    expect(drawer.currentState!.isOpen, isFalse);
  });

  testWidgets('关闭遮罩的点击不穿透，同帧下一次点击可以操作列表', (tester) async {
    var taps = 0;
    final (drawer, _) = await pumpHome(tester, onTopicTap: () => taps++);
    await tester.tapAt(const Offset(350, 400));
    expect(taps, 0);
    expect(drawer.currentState!.isOpen, isTrue);
    await tester.tapAt(const Offset(350, 400));
    expect(taps, 1);
    await tester.pumpAndSettle();
    expect(drawer.currentState!.isOpen, isFalse);
  });

  for (final commit in [true, false]) {
    testWidgets('预测返回${commit ? '提交后立即放行列表' : '取消后仍由侧栏接收输入'}', (tester) async {
      final (drawer, list) = await pumpHome(tester);
      await sendBack('startBackGesture');
      await sendBack('updateBackGestureProgress', 0.3);
      await tester.pump();
      await sendBack(commit ? 'commitBackGesture' : 'cancelBackGesture');
      expect(drawer.currentState!.isOpen, isTrue);

      final before = list.offset;
      final gesture = await tester.startGesture(const Offset(350, 400));
      await gesture.moveBy(const Offset(3, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(4, -100));
      await tester.pump();
      if (commit) {
        expect(list.offset - before, greaterThan(60));
      } else {
        expect(list.offset, before);
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(drawer.currentState!.isOpen, !commit);
    });
  }

  testWidgets('侧栏收起期间卸载不遗留动画回调', (tester) async {
    final (drawer, _) = await pumpHome(tester);
    drawer.currentState!.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
