import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Metrics extends StatelessWidget {
  const _Metrics(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Text(
      '$name:${constraints.maxHeight}:'
      '${MediaQuery.viewInsetsOf(context).bottom}:'
      '${MediaQuery.paddingOf(context).bottom}',
    ),
  );
}

void main() {
  void setupView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
  }

  testWidgets('后台 tab 保持高度，活动 tab 避让；切 tab 和收键盘同步恢复', (tester) async {
    setupView(tester);
    final active = ValueNotifier(0);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: active,
            builder: (context, index, _) => IndexedStack(
              index: index,
              children: [
                for (var i = 0; i < 2; i++)
                  KeyboardInsetIsolation(
                    active: i == index,
                    child: _Metrics('$i'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('1:600.0:0.0:0.0', skipOffstage: false), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    expect(find.text('0:360.0:0.0:0.0'), findsOneWidget);
    expect(find.text('1:600.0:0.0:0.0', skipOffstage: false), findsOneWidget);

    active.value = 1;
    await tester.pump();
    expect(find.text('1:360.0:0.0:0.0'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    expect(find.text('0:600.0:0.0:0.0', skipOffstage: false), findsOneWidget);
    expect(find.text('1:600.0:0.0:0.0'), findsOneWidget);
  });

  testWidgets('后台保留底部 inset/padding，窗口旋转和文字缩放仍更新', (tester) async {
    setupView(tester);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    await tester.pumpWidget(
      const MaterialApp(
        home: KeyboardInsetIsolation(
          active: false,
          child: _Metrics('background'),
        ),
      ),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    tester.view.padding = const FakeViewPadding();
    await tester.pump();
    expect(find.text('background:600.0:0.0:24.0'), findsOneWidget);
    tester.view.physicalSize = const Size(600, 800);
    await tester.pump();
    expect(find.text('background:800.0:240.0:0.0'), findsOneWidget);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    final context = tester.element(find.byType(_Metrics));
    expect(MediaQuery.textScalerOf(context).scale(10), 15);
  });

  testWidgets('被路由覆盖时隔离，返回后追上实时键盘高度', (tester) async {
    setupView(tester);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(
          body: KeyboardInsetIsolation(child: _Metrics('home')),
        ),
      ),
    );
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    expect(find.text('home:600.0:0.0:0.0'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home:360.0:0.0:0.0'), findsOneWidget);
  });

  testWidgets('双栏只让持有输入焦点的一栏跟随键盘', (tester) async {
    setupView(tester);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(
                child: KeyboardInsetIsolation(
                  requireFocus: true,
                  child: _Metrics('left'),
                ),
              ),
              Expanded(
                child: KeyboardInsetIsolation(
                  requireFocus: true,
                  child: Column(
                    children: [
                      TextField(focusNode: focus),
                      const Expanded(child: _Metrics('right')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    expect(find.text('left:600.0:0.0:0.0'), findsOneWidget);
    final right = tester.getSize(
      find.byWidgetPredicate(
        (widget) => widget is _Metrics && widget.name == 'right',
      ),
    );
    expect(right.height, lessThan(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套 Navigator 被外层路由盖住时也隔离键盘', (tester) async {
    setupView(tester);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: KeyboardInsetIsolation(child: _Metrics('nested')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    expect(find.text('nested:600.0:0.0:0.0'), findsOneWidget);
  });
}
