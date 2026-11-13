import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Color> _pixelAt(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Offset position,
) async {
  return (await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final index =
          (position.dy.floor() * image.width + position.dx.floor()) * 4;
      return Color.fromARGB(
        pixels.getUint8(index + 3),
        pixels.getUint8(index),
        pixels.getUint8(index + 1),
        pixels.getUint8(index + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('单面板收回经过按钮与菜单之间，保留完整回程而非原地淡出', (tester) async {
    final screenKey = GlobalKey();
    const anchorKey = ValueKey('return-anchor');
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 60),
                child: SwipeDismissiblePopupMenuButton<int>(
                  position: PopupMenuPosition.under,
                  offset: const Offset(0, 96),
                  color: Colors.green,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('Choose')),
                  ],
                  child: SizedBox(
                    key: anchorKey,
                    width: 120,
                    height: 40,
                    child: ColoredBox(color: Colors.red),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(anchorKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final anchor = tester.getRect(find.byKey(anchorKey));
    final returning = await _pixelAt(
      tester,
      screenKey,
      Offset(anchor.center.dx, anchor.bottom + 46),
    );
    expect(returning.g, greaterThan(returning.r), reason: '面板应经过回到真实按钮的路径');
    expect(
      (await _pixelAt(tester, screenKey, anchor.center)).toARGB32(),
      Colors.red.toARGB32(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose'), findsNothing);
  });

  testWidgets('展开时内容随轮廓宽度等比放大', (tester) async {
    const anchorKey = ValueKey('grow-anchor');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 60),
              child: SwipeDismissiblePopupMenuButton<int>(
                position: PopupMenuPosition.under,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1, child: Text('Choose')),
                ],
                child: const SizedBox(
                  key: anchorKey,
                  width: 40,
                  height: 40,
                  child: Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(anchorKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final early = tester.getRect(find.text('Choose'));
    await tester.pumpAndSettle();
    final settled = tester.getRect(find.text('Choose'));
    expect(early.width / settled.width, lessThan(.9), reason: '内容应随轮廓宽度缩放');
    expect(
      early.height / early.width,
      closeTo(settled.height / settled.width, .01),
      reason: '内容必须等比缩放，不能拉伸',
    );
  });

  testWidgets('向下展开时内容贴远端，不会先冲过终点再爬回', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SwipeDismissiblePopupMenuButton<int>(
                position: PopupMenuPosition.under,
                itemBuilder: (_) => [
                  for (var i = 0; i < 8; i++)
                    PopupMenuItem(value: i, child: Text('Item $i')),
                ],
                child: const SizedBox(
                  width: 48,
                  height: 40,
                  child: Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    final first = <double>[], last = <double>[];
    for (var frame = 0; frame < 30; frame++) {
      first.add(tester.getRect(find.text('Item 0')).top);
      last.add(tester.getRect(find.text('Item 7')).bottom);
      await tester.pump(const Duration(microseconds: 11111));
    }
    await tester.pumpAndSettle();
    final firstEnd = tester.getRect(find.text('Item 0')).top;
    for (var i = 1; i < last.length; i++) {
      expect(
        last[i],
        greaterThanOrEqualTo(last[i - 1] - .001),
        reason: '远端第 $i 帧',
      );
    }
    expect(
      first.reduce(math.max) - firstEnd,
      lessThan(12),
      reason: '靠近入口的一侧只允许轻微冲出',
    );
  });

  testWidgets('菜单贴屏幕右缘时子面板与入口行同宽，揭开全程不错位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SwipeDismissiblePopupMenuButton<int>(
              position: PopupMenuPosition.under,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('Parent')),
                ExpandablePopupMenuEntry<int>(
                  icon: Icons.sort,
                  label: 'Sort',
                  children: [
                    ExpandableMenuChild(
                      value: 2,
                      icon: Icons.check,
                      label: 'Child',
                    ),
                  ],
                ),
              ],
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final entry = tester.getRect(find.text('Sort'));
    final parentWidth = tester.getSize(find.byType(ListBody)).width;
    await tester.tap(find.text('Sort'));
    await tester.pump();
    for (var frame = 0; frame < 20; frame++) {
      expect(
        tester.getRect(find.text('Sort').last).left,
        closeTo(entry.left, .5),
        reason: '第 $frame 帧头部与入口错位会出现重影',
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(SingleChildScrollView).last).width,
      closeTo(parentWidth, .5),
      reason: '内容放得下时子面板与一级菜单同宽',
    );
  });

  testWidgets('子菜单从入口行原地揭开，箭头转向上方，返回时转回', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeDismissiblePopupMenuButton<int>(
              position: PopupMenuPosition.under,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('Parent')),
                ExpandablePopupMenuEntry<int>(
                  icon: Icons.sort,
                  label: 'Sort',
                  children: [
                    ExpandableMenuChild(
                      value: 2,
                      icon: Icons.check,
                      label: 'Child',
                    ),
                  ],
                ),
              ],
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final entry = tester.getRect(find.text('Sort'));
    double chevronTurns() => tester
        .widget<RotationTransition>(
          find.ancestor(
            of: find.byIcon(Symbols.keyboard_arrow_right_rounded).last,
            matching: find.byType(RotationTransition),
          ),
        )
        .turns
        .value;

    await tester.tap(find.text('Sort'));
    await tester.pump();
    final header = find.text('Sort').last;
    expect(
      (tester.getRect(header).topLeft - entry.topLeft).distance,
      lessThan(.5),
      reason: '面板头部应从入口行原位升起，与入口逐像素重合',
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      entry.top - tester.getRect(header).top,
      greaterThan(3),
      reason: '松手后立即起步，不能从静止慢慢加速',
    );
    expect(tester.getRect(header).left, closeTo(entry.left, .5));
    expect(
      tester.getRect(header).height,
      closeTo(entry.height, .01),
      reason: '揭开过程中内容保持原尺寸',
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(header).left, closeTo(entry.left, .5));
    expect(tester.getRect(header).top, closeTo(entry.top - 16, .5));
    expect(chevronTurns(), closeTo(-.25, 1e-6));

    await Navigator.of(tester.element(find.text('Child'))).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(chevronTurns(), greaterThan(-.25));
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsNothing);
    expect(find.text('Sort'), findsOneWidget);
  });

  for (final mode in ['展开完成后', '展开途中', '划选松手后']) {
    final partial = mode == '展开途中';
    final drag = mode == '划选松手后';
    testWidgets('一级和二级$mode关闭，子菜单立即消失，一级菜单归位后收回', (tester) async {
      const entryKey = ValueKey('chain-anchor');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 60),
                child: SwipeDismissiblePopupMenuButton<int>(
                  position: PopupMenuPosition.under,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('Parent marker')),
                    ExpandablePopupMenuEntry<int>(
                      icon: Icons.sort,
                      label: 'Sort',
                      children: [
                        ExpandableMenuChild(
                          value: 2,
                          icon: Icons.check,
                          label: 'Child marker',
                        ),
                      ],
                    ),
                  ],
                  child: SizedBox(
                    key: entryKey,
                    width: 120,
                    height: 40,
                    child: Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      TestGesture? gesture;
      if (drag) {
        gesture = await tester.startGesture(
          tester.getCenter(find.byKey(entryKey)),
        );
      } else {
        await tester.tap(find.byKey(entryKey));
      }
      await tester.pumpAndSettle();
      final parent = find.text('Parent marker');
      final child = find.text('Child marker');
      final parentRest = tester.getCenter(parent);
      if (drag) {
        await gesture!.moveTo(tester.getCenter(find.text('Sort')));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        await gesture.moveTo(tester.getCenter(child));
      } else {
        await tester.tap(find.text('Sort'));
      }
      if (partial) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
      } else {
        await tester.pumpAndSettle();
      }
      expect(child, findsOneWidget);
      if (drag) {
        await gesture!.up();
      } else if (partial) {
        // 子菜单还未完全展开时点击外部，同一帧关闭整组。
        await tester.tapAt(const Offset(700, 500));
      } else {
        await tester.tap(child);
      }
      await tester.pump();
      expect(child, findsNothing, reason: '子菜单应立即移除，不参与收回动画');
      expect(
        (tester.getCenter(parent) - parentRest).distance,
        lessThan(.1),
        reason: '一级菜单先归位，再从完整状态收回',
      );
      // 靠近入口的边会先略微冲出再回收,远端的边才是单调收回的参照。
      final pivot = tester.getCenter(find.byKey(entryKey));
      final far = find.text('Sort');
      var previous = (tester.getCenter(far) - pivot).distance;
      for (var elapsed = 16; elapsed <= 160; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        final distance = (tester.getCenter(far) - pivot).distance;
        expect(
          distance,
          lessThanOrEqualTo(previous + .001),
          reason: '$elapsed ms 一级菜单只能朝入口收回',
        );
        previous = distance;
      }
      await tester.pumpAndSettle();
      expect(parent, findsNothing);
      await gesture?.removePointer();
    });
  }

  testWidgets('只返回一级菜单时正常恢复尺寸，可以继续选择', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeDismissiblePopupMenuButton<int>(
              position: PopupMenuPosition.under,
              onSelected: (_) => calls++,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('Parent')),
                ExpandablePopupMenuEntry<int>(
                  icon: Icons.sort,
                  label: 'Sort',
                  children: [
                    ExpandableMenuChild(
                      value: 2,
                      icon: Icons.check,
                      label: 'Child',
                    ),
                  ],
                ),
              ],
              child: Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final parentPosition = tester.getCenter(find.text('Parent'));
    await tester.tap(find.text('Sort'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('Parent')), isNot(parentPosition));
    await Navigator.of(tester.element(find.text('Child'))).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsNothing);
    expect(tester.getCenter(find.text('Parent')), parentPosition);
    await tester.tap(find.text('Parent'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  for (final submenu in [false, true]) {
    testWidgets('菜单${submenu ? '级联' : '直接'}选择时入口持续显示最新状态，收回逐帧不闪回旧截图', (
      tester,
    ) async {
      final boundaryKey = GlobalKey();
      const buttonKey = ValueKey('live-menu-button');
      var opened = false;
      var selected = false;
      var calls = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: StatefulBuilder(
                    builder: (context, update) =>
                        SwipeDismissiblePopupMenuButton<int>(
                          position: PopupMenuPosition.under,
                          onOpened: () => update(() => opened = true),
                          onSelected: (_) => update(() {
                            opened = false;
                            selected = true;
                            calls++;
                          }),
                          itemBuilder: (_) => submenu
                              ? const [
                                  ExpandablePopupMenuEntry<int>(
                                    icon: Icons.sort,
                                    label: 'Sort',
                                    children: [
                                      ExpandableMenuChild(
                                        value: 1,
                                        icon: Icons.check,
                                        label: 'Choose',
                                      ),
                                    ],
                                  ),
                                ]
                              : const [
                                  PopupMenuItem(
                                    value: 1,
                                    child: Text('Choose'),
                                  ),
                                ],
                          child: SizedBox(
                            key: buttonKey,
                            width: selected ? 180 : 120,
                            height: 40,
                            child: ColoredBox(
                              color: selected
                                  ? Colors.blue
                                  : opened
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(buttonKey);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        (await _pixelAt(
          tester,
          boundaryKey,
          tester.getCenter(button),
        )).toARGB32(),
        Colors.green.toARGB32(),
        reason: '打开菜单后，真实入口及其 onOpened 状态仍可见',
      );
      if (submenu) {
        await tester.tap(find.text('Sort'));
        await tester.pumpAndSettle();
        expect(
          (await _pixelAt(
            tester,
            boundaryKey,
            tester.getCenter(button),
          )).toARGB32(),
          Colors.green.toARGB32(),
        );
      }
      await tester.tap(find.text('Choose'));
      await tester.pump();
      expect(calls, 1);
      expect(tester.getSize(button).width, 180);
      for (var elapsed = 0; elapsed <= 272; elapsed += 16) {
        final color = await _pixelAt(
          tester,
          boundaryKey,
          tester.getCenter(button),
        );
        expect(
          color.b,
          greaterThan(color.r),
          reason: '收回第 $elapsed ms 应显示蓝色新状态，不能空白或闪回红色旧状态',
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(
        (await _pixelAt(
          tester,
          boundaryKey,
          tester.getCenter(button),
        )).toARGB32(),
        Colors.blue.toARGB32(),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(submenu ? 'Sort' : 'Choose'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
