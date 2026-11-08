import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/pane_filmstrip.dart';

/// 胶片带契约:
/// - 格子 Element 恒驻:压栈后旧顶格滑去左栏(unpinned),State 不丢;
///   退栈后倒二格回右栏,State 不丢;
/// - 出场格动画期在场,完成后移除;
/// - animate:false 瞬切;
/// - 投影(viewportPanes=1)只露栈顶格;
/// - pinned 模式 master 恒在左栏。
void main() {
  testWidgets('预测返回提交后退出格从当前进度收尾，下层立即可滚动', (tester) async {
    final scroll = ScrollController(initialScrollOffset: 400);
    addTearDown(scroll.dispose);
    addTearDown(() => PaneProjectionBack.progress.value = 0);
    late BuildContext owner;
    Widget page(bool detail) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            owner = context;
            return PaneFilmstrip(
              master: ListView.builder(
                controller: scroll,
                itemCount: 100,
                itemExtent: 60,
                itemBuilder: (_, i) => Text('row $i'),
              ),
              panes: detail
                  ? [
                      const ColoredBox(
                        key: ValueKey('exit'),
                        color: Colors.blue,
                      ),
                    ]
                  : [],
              masterWidth: 400,
              viewportPanes: 1,
              pinMaster: false,
              bandDrag: PaneProjectionBack.progress,
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    PaneProjectionBack.progress.value = .35;
    await tester.pump();
    final exiting = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.key == const ValueKey('exit'),
    );
    final before = tester.getTopLeft(exiting).dx;
    PaneProjectionBack.commitExit(owner, .35);
    PaneProjectionBack.progress.value = 0;
    await tester.pumpWidget(page(false));
    expect(tester.getTopLeft(exiting).dx, closeTo(before, .1));
    final start = scroll.offset;
    final drag = await tester.startGesture(const Offset(600, 300));
    await drag.moveBy(const Offset(3, -30));
    await tester.pump();
    await drag.moveBy(const Offset(4, -100));
    await tester.pump();
    expect(scroll.offset - start, greaterThan(60));
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('exit')), findsNothing);
  });

  for (final expire in [false, true]) {
    testWidgets('退出进度仅归对应宿主且下一帧失效 expire=$expire', (tester) async {
      late BuildContext owner;
      Widget strip(int index, bool detail) => Builder(
        builder: (context) {
          if (index == 1) owner = context;
          return PaneFilmstrip(
            master: const SizedBox.expand(),
            panes: detail
                ? [ColoredBox(key: ValueKey(index), color: Colors.blue)]
                : [],
            viewportPanes: 1,
            masterWidth: 400,
            pinMaster: false,
          );
        },
      );
      Widget page(bool detail) => MaterialApp(
        home: Row(
          children: [
            Expanded(child: strip(0, detail)),
            Expanded(child: strip(1, detail)),
          ],
        ),
      );
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      PaneProjectionBack.commitExit(owner, .5);
      if (expire) await tester.pump();
      await tester.pumpWidget(page(false));
      Finder pane(int index) => find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.key == ValueKey(index),
      );
      expect(tester.getTopLeft(pane(0)).dx, 0, reason: '另一个宿主不得消费进度');
      expect(tester.getTopLeft(pane(1)).dx, expire ? 400 : 600);
      await tester.pumpAndSettle();
    });
  }

  Widget host({
    required List<Widget> panes,
    bool pinMaster = false,
    int viewportPanes = 2,
    bool animate = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PaneFilmstrip(
          master: const Text('列表'),
          panes: panes,
          emptyPane: const Text('空态'),
          pinMaster: pinMaster,
          viewportPanes: viewportPanes,
          masterWidth: 400,
          animate: animate,
        ),
      ),
    );
  }

  Future<void> pumpWide(WidgetTester tester, Widget w) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpWidget(w);
  }

  testWidgets('压栈:旧顶格滑去左栏,State 不丢;退栈滑回仍不丢', (tester) async {
    addTearDown(tester.view.reset);
    await pumpWide(tester, host(panes: [const _Counter(key: ValueKey('a'))]));
    await tester.pumpAndSettle();

    // 计数 +1
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    // 压栈:格 a 滑去左栏,格 b 入场
    await pumpWide(
      tester,
      host(
        panes: [
          const _Counter(key: ValueKey('a')),
          const Text('层B', key: ValueKey('b')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('层B'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '格 a 滑到左栏,State 必须保留');

    // 退栈:格 b 出场,格 a 滑回右栏
    await pumpWide(tester, host(panes: [const _Counter(key: ValueKey('a'))]));
    await tester.pumpAndSettle();
    expect(find.text('层B'), findsNothing);
    expect(find.text('1'), findsOneWidget, reason: '格 a 滑回右栏,State 必须保留');
  });

  testWidgets('退栈动画期出场格在场,完成后移除', (tester) async {
    addTearDown(tester.view.reset);
    await pumpWide(
      tester,
      host(
        panes: [
          const Text('层A', key: ValueKey('a')),
          const Text('层B', key: ValueKey('b')),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await pumpWide(tester, host(panes: [const Text('层A', key: ValueKey('a'))]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 飞行中:出场格 b 仍在树上(向右滑出中)
    expect(find.text('层B', skipOffstage: false), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('层B', skipOffstage: false), findsNothing);
    expect(find.text('层A'), findsOneWidget);
  });

  testWidgets('animate:false 瞬切,无中间态', (tester) async {
    addTearDown(tester.view.reset);
    await pumpWide(
      tester,
      host(panes: [const Text('层A', key: ValueKey('a'))], animate: false),
    );
    await tester.pump();

    await pumpWide(
      tester,
      host(
        panes: [
          const Text('层A', key: ValueKey('a')),
          const Text('层B', key: ValueKey('b')),
        ],
        animate: false,
      ),
    );
    await tester.pump();
    expect(find.text('层B'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('投影视口只露栈顶格,master 在带外保活', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        panes: [
          const Text('层A', key: ValueKey('a')),
          const Text('层B', key: ValueKey('b')),
        ],
        viewportPanes: 1,
      ),
    );
    await tester.pumpAndSettle();
    // 视口内只有栈顶
    expect(find.text('层B'), findsOneWidget);
    expect(find.text('层A'), findsNothing);
    // 带外格保活(Offstage 在树)
    expect(find.text('层A', skipOffstage: false), findsOneWidget);
    expect(find.text('列表', skipOffstage: false), findsOneWidget);
  });

  testWidgets('pinned:master 恒在左栏,层带只在右格区', (tester) async {
    addTearDown(tester.view.reset);
    await pumpWide(
      tester,
      host(
        panes: [
          const Text('层A', key: ValueKey('a')),
          const Text('层B', key: ValueKey('b')),
        ],
        pinMaster: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('层B'), findsOneWidget);
    // 非顶层格滑到右格区左带外,不可见但保活
    expect(find.text('层A'), findsNothing);
    expect(find.text('层A', skipOffstage: false), findsOneWidget);
  });

  testWidgets('栈空:显示空态', (tester) async {
    addTearDown(tester.view.reset);
    await pumpWide(tester, host(panes: const []));
    await tester.pumpAndSettle();
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('空态'), findsOneWidget);
  });

  testWidgets('masterFillsWhenEmpty:栈空 master 撑满且恒无空态,压栈收窄', (tester) async {
    addTearDown(tester.view.reset);
    Widget fillHost(List<Widget> panes) => MaterialApp(
      home: Scaffold(
        body: PaneFilmstrip(
          master: const SizedBox.expand(key: ValueKey('m'), child: Text('资料页')),
          panes: panes,
          emptyPane: const Text('空态'),
          masterFillsWhenEmpty: true,
          pinMaster: false,
          viewportPanes: 2,
          masterWidth: 700,
        ),
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);

    // 栈空:master 独占视口,空态不得挂载(挂上会盖住右半,实测截图)
    await tester.pumpWidget(fillHost(const []));
    await tester.pumpAndSettle();
    expect(find.text('空态', skipOffstage: false), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('m'))).width, 1400);

    // 压栈:master 收窄成左栏,层格入场
    await tester.pumpWidget(fillHost([const Text('层A', key: ValueKey('a'))]));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('m'))).width, 700);
    expect(find.text('层A'), findsOneWidget);

    // 退栈回空:出场动画期与稳态都不得出现空态,master 回全宽
    await tester.pumpWidget(fillHost(const []));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('空态', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('空态', skipOffstage: false), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('m'))).width, 1400);
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: () => setState(() => n++), child: Text('$n'));
  }
}
