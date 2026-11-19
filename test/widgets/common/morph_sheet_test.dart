import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:material_ui/material_ui.dart';

const _source = Rect.fromLTWH(20, 220, 360, 160);
const _sheet = ValueKey('editor');

Future<NavigatorState> _open(
  WidgetTester tester, {
  required MorphSheetAnchor? Function() target,
  VoidCallback? onHandoff,
  Widget? child,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(navigatorKey: navigator, home: const Scaffold()),
  );
  showAppMorphSheet<void>(
    context: tester.element(find.byType(Scaffold)),
    fromRect: _source,
    returnAnchor: target,
    onHandoffComplete: onHandoff,
    suspendDynamicContent: false,
    builder: (_) => FractionallySizedBox(
      heightFactor: .95,
      child: ColoredBox(
        key: _sheet,
        color: Colors.white,
        child: child ?? const SizedBox.expand(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return navigator.currentState!;
}

Rect _bounds(WidgetTester tester) {
  final clip = find
      .ancestor(of: find.byType(BottomSheet), matching: find.byType(ClipPath))
      .first;
  return tester
      .widget<ClipPath>(clip)
      .clipper!
      .getClip(tester.getSize(clip))
      .getBounds();
}

void main() {
  testWidgets('入场从快捷回复展开，关闭时跟随移动后的回复胶囊', (tester) async {
    var handoffs = 0;
    var rect = const Rect.fromLTWH(144, 505, 164, 36);
    final nav = await _open(
      tester,
      target: () => (rect: rect, radius: 18, color: Colors.blue),
      onHandoff: () => handoffs++,
    );
    expect(_bounds(tester), _source);
    await tester.pumpAndSettle();
    expect(handoffs, 1);
    nav.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    rect = rect.shift(const Offset(12, 40));
    await tester.pump(const Duration(milliseconds: 189));
    final end = _bounds(tester);
    expect(end.left, closeTo(rect.left, 1));
    expect(end.top, closeTo(rect.top, 1));
    expect(end.width, closeTo(rect.width, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
    expect(handoffs, 1);
  });

  testWidgets('下拉跟手，短拖回弹，关闭手势尊重 PopScope', (tester) async {
    final allowPop = ValueNotifier(false);
    addTearDown(allowPop.dispose);
    var blocked = 0;
    await _open(
      tester,
      target: () => null,
      child: ValueListenableBuilder(
        valueListenable: allowPop,
        builder: (_, allow, _) => PopScope<void>(
          canPop: allow,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) blocked++;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final full = _bounds(tester);
    final start = Offset(full.center.dx, full.top + 16);
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(0, 22));
    await drag.moveBy(const Offset(0, 66));
    await tester.pump();
    expect(_bounds(tester).top, greaterThan(full.top + 40));
    await drag.up();
    await tester.pumpAndSettle();
    expect(_bounds(tester), full);
    expect(blocked, 0);
    await tester.flingFrom(start, const Offset(0, 220), 1800);
    await tester.pumpAndSettle();
    expect(blocked, 1);
    expect(_bounds(tester), full);
    allowPop.value = true;
    await tester.pump();
    await tester.flingFrom(start, const Offset(0, 220), 1800);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
  });

  testWidgets('展开途中返回，保留快捷回复直到反向动画走完', (tester) async {
    var handoffs = 0;
    final nav = await _open(
      tester,
      target: () => null,
      onHandoff: () => handoffs++,
    );
    await tester.pump(const Duration(milliseconds: 150));
    nav.pop();
    await tester.pump();
    expect(handoffs, 0);
    await tester.pumpAndSettle();
    expect(handoffs, 1);
  });

  testWidgets('起点元素在弹层真正画出之后才隐藏，没有空白帧', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    var shownAt = -1;
    var frame = 0;
    showAppMorphSheet<void>(
      context: tester.element(find.byType(Scaffold)),
      fromRect: _source,
      suspendDynamicContent: false,
      onHandoffStart: () => shownAt = frame,
      builder: (_) => const SizedBox.expand(),
    );
    // 入场首帧路由被 HeroController 置为 offstage 测量，不绘制：此时
    // 起点元素必须还在
    frame = 1;
    await tester.pump();
    expect(shownAt, -1);
    // 之后弹层第一次绘制，帧尾才通知隐藏起点
    for (frame = 2; frame < 5 && shownAt < 0; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shownAt, greaterThan(1));
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
