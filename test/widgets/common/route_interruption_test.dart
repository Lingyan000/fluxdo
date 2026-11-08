import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/widgets/common/fullscreen_swipe_back.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

void main() {
  final binding = _Binding();

  Future<(GlobalKey<NavigatorState>, ScrollController)> home(
    WidgetTester tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final scroll = ScrollController(initialScrollOffset: 400);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [RouteInteractionObserver()],
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: InterruptiblePageTransitionsBuilder(
                FullscreenSwipeBackTransitionsBuilder(
                  PredictiveBackCupertinoPageTransitionsBuilder(),
                ),
              ),
              TargetPlatform.iOS: InterruptiblePageTransitionsBuilder(
                FullscreenSwipeBackTransitionsBuilder(
                  CupertinoPageTransitionsBuilder(),
                ),
              ),
            },
          ),
        ),
        home: Scaffold(
          body: ListView.builder(
            controller: scroll,
            itemCount: 100,
            itemExtent: 60,
            itemBuilder: (_, i) => Text('row $i'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (nav, scroll);
  }

  Future<void> swipe(
    WidgetTester tester,
    ScrollController scroll, {
    bool moves = true,
    Offset start = const Offset(400, 300),
  }) async {
    final before = scroll.offset;
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(3, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(4, -100));
    await tester.pump();
    expect(scroll.offset - before, moves ? greaterThan(60) : 0);
    await gesture.cancel();
  }

  Future<void> sendBack(String method, [double progress = 0]) =>
      binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, {
            'touchOffset': <double>[0, 300],
            'progress': progress,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );

  for (final kind in ['dialog', 'general', 'sheet', 'material', 'menu']) {
    for (final delay in [0, 16, 80]) {
      testWidgets('$kind 关闭后立即滚动底层 delay=$delay', (tester) async {
        final (nav, scroll) = await home(tester);
        final context = nav.currentState!.overlay!.context;
        switch (kind) {
          case 'dialog':
            showAppDialog<void>(
              context: context,
              blur: false,
              builder: (_) => const Dialog(
                child: SizedBox(height: 160, child: Text('overlay')),
              ),
            );
          case 'general':
            showAppGeneralDialog<void>(
              context: context,
              blur: false,
              pageBuilder: (_, _, _) => const Center(
                child: Material(
                  child: SizedBox(
                    width: 300,
                    height: 160,
                    child: Text('overlay'),
                  ),
                ),
              ),
            );
          case 'sheet':
            showAppBottomSheet<void>(
              context: context,
              blur: false,
              builder: (_) =>
                  const SizedBox(height: 220, child: Text('overlay')),
            );
          case 'material':
            showInteractionDialog<void>(
              context: context,
              builder: (_) => const Dialog(
                child: SizedBox(height: 160, child: Text('overlay')),
              ),
            );
          case 'menu':
            showSwipeDismissibleMenu<int>(
              context: context,
              position: const RelativeRect.fromLTRB(350, 250, 200, 200),
              items: const [PopupMenuItem(value: 1, child: Text('overlay'))],
            );
        }
        await tester.pumpAndSettle();
        if (kind != 'menu') {
          await swipe(
            tester,
            scroll,
            moves: false,
            start: const Offset(50, 200),
          );
          await tester.pumpAndSettle();
        }
        nav.currentState!.pop();
        if (delay > 0) {
          await tester.pump();
          await tester.pump(Duration(milliseconds: delay));
        }
        await swipe(tester, scroll);
        await tester.pumpAndSettle();
        expect(nav.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('关闭后同帧打开新的弹窗仍阻挡底层', (tester) async {
    final (nav, scroll) = await home(tester);
    void open() => showInteractionDialog<void>(
      context: nav.currentState!.overlay!.context,
      builder: (_) => const Dialog(child: Text('overlay')),
    );
    open();
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    open();
    await swipe(tester, scroll, moves: false);
    await tester.pumpAndSettle();
    expect(nav.currentState!.canPop(), isTrue);
  });

  testWidgets('返回只消耗弹层 LocalHistoryEntry 时不释放输入', (tester) async {
    final (nav, scroll) = await home(tester);
    late ModalRoute<dynamic> route;
    showInteractionDialog<void>(
      context: nav.currentState!.overlay!.context,
      builder: (context) {
        route = ModalRoute.of(context)!;
        return const Dialog(child: Text('overlay'));
      },
    );
    await tester.pumpAndSettle();
    route.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {}));
    nav.currentState!.pop();
    await swipe(tester, scroll, moves: false);
    await tester.pumpAndSettle();
    expect(route.isCurrent, isTrue);
  });

  testWidgets('关闭一层弹窗仍保留下层弹窗的拦截', (tester) async {
    final (nav, scroll) = await home(tester);
    void open(String name) => showInteractionDialog<void>(
      context: nav.currentState!.overlay!.context,
      builder: (_) => Dialog(child: Text(name)),
    );
    open('lower');
    await tester.pumpAndSettle();
    open('upper');
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await swipe(tester, scroll, moves: false);
    await tester.pumpAndSettle();
    expect(find.text('lower'), findsOneWidget);
    expect(find.text('upper'), findsNothing);
  });

  testWidgets('关闭弹窗的那次点击不穿透，同帧下一次点击可操作', (tester) async {
    final (nav, _) = await home(tester);
    var taps = 0;
    final page = InteractionPageRoute<void>(
      builder: (_) => GestureDetector(
        onTap: () => taps++,
        child: const ColoredBox(color: Colors.blue),
      ),
    );
    nav.currentState!.push(page);
    await tester.pumpAndSettle();
    showInteractionDialog<void>(
      context: nav.currentState!.overlay!.context,
      builder: (_) => const Dialog(child: Text('overlay')),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(50, 200));
    expect(taps, 0);
    await tester.tapAt(const Offset(50, 200));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  for (final ignore in [false, true]) {
    testWidgets('预测返回拖动中不放行，回弹尊重业务 IgnorePointer=$ignore', (tester) async {
      final (nav, _) = await home(tester);
      final scroll = ScrollController(initialScrollOffset: 400);
      addTearDown(scroll.dispose);
      nav.currentState!.push(
        InteractionPageRoute<void>(
          builder: (_) => Scaffold(
            body: IgnorePointer(
              ignoring: ignore,
              child: ListView.builder(
                controller: scroll,
                itemExtent: 60,
                itemCount: 100,
                itemBuilder: (_, i) => Text('detail $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await sendBack('startBackGesture');
      await sendBack('updateBackGestureProgress', .2);
      await tester.pump();
      await swipe(tester, scroll, moves: false, start: const Offset(600, 300));
      await sendBack('cancelBackGesture');
      await swipe(
        tester,
        scroll,
        moves: !ignore,
        start: const Offset(600, 300),
      );
      await tester.pumpAndSettle();
      expect(nav.currentState!.userGestureInProgress, isFalse);
    });
  }

  testWidgets('嵌套 Navigator 的弹窗关闭能交还内栏列表', (tester) async {
    final inner = GlobalKey<NavigatorState>();
    final scroll = ScrollController(initialScrollOffset: 400);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          key: inner,
          observers: [RouteInteractionObserver()],
          onGenerateRoute: (_) => InteractionPageRoute<void>(
            builder: (_) => Scaffold(
              body: ListView.builder(
                controller: scroll,
                itemExtent: 60,
                itemCount: 100,
                itemBuilder: (_, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    showInteractionDialog<void>(
      context: inner.currentState!.overlay!.context,
      useRootNavigator: false,
      builder: (_) => const Dialog(child: Text('overlay')),
    );
    await tester.pumpAndSettle();
    inner.currentState!.pop();
    await swipe(tester, scroll);
    await tester.pumpAndSettle();
  });

  testWidgets(
    '全屏返回回弹期间立即竖滑当前页列表',
    (tester) async {
      final (nav, _) = await home(tester);
      final scroll = ScrollController(initialScrollOffset: 400);
      addTearDown(scroll.dispose);
      final route = InteractionPageRoute<void>(
        builder: (_) => Scaffold(
          body: ListView.builder(
            controller: scroll,
            itemCount: 100,
            itemExtent: 60,
            itemBuilder: (_, i) => Text('detail $i'),
          ),
        ),
      );
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(const Offset(250, 300));
      await drag.moveBy(const Offset(30, 0));
      await tester.pump();
      await drag.moveBy(const Offset(150, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(route.animation!.value, lessThan(1));
      await swipe(tester, scroll, start: const Offset(600, 300));
      await tester.pumpAndSettle();
      expect(route.isCurrent, isTrue);
      expect(nav.currentState!.userGestureInProgress, isFalse);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final custom in [false, true]) {
    testWidgets('普通页面 pop 首次布局后底层可滚动 custom=$custom', (tester) async {
      final (nav, scroll) = await home(tester);
      final page = const Scaffold(body: Text('detail'));
      final route = custom
          ? InteractionPageRouteBuilder<void>(
              pageBuilder: (_, _, _) => page,
              reverseTransitionDuration: const Duration(milliseconds: 300),
              transitionsBuilder: (_, animation, _, child) =>
                  FadeTransition(opacity: animation, child: child),
            )
          : InteractionPageRoute<void>(builder: (_) => page);
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      // Opaque pages can keep the underlying page offstage until this layout.
      await tester.pump();
      expect(route.animation!.value, greaterThan(0));
      await swipe(tester, scroll);
      await tester.pumpAndSettle();
      expect(nav.currentState!.canPop(), isFalse);
    });
  }

  for (final commit in [true, false]) {
    testWidgets('预测返回 ${commit ? '提交' : '取消'} 收尾期间当前页可滚动', (tester) async {
      final (nav, base) = await home(tester);
      final detail = ScrollController(initialScrollOffset: 400);
      addTearDown(detail.dispose);
      final route = InteractionPageRoute<void>(
        builder: (_) => Scaffold(
          body: ListView.builder(
            controller: detail,
            itemCount: 100,
            itemExtent: 60,
            itemBuilder: (_, i) => Text('detail $i'),
          ),
        ),
      );
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      await sendBack('startBackGesture');
      await sendBack('updateBackGestureProgress', .3);
      await tester.pump();
      await sendBack(commit ? 'commitBackGesture' : 'cancelBackGesture');
      await swipe(
        tester,
        commit ? base : detail,
        start: const Offset(600, 300),
      );
      await tester.pumpAndSettle();
      expect(route.isCurrent, !commit);
      expect(nav.currentState!.userGestureInProgress, isFalse);
    });
  }
}
