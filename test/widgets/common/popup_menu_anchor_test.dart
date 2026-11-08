import 'dart:ui' as ui;

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
    await tester.pump(const Duration(milliseconds: 120));
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

  for (final mode in ['展开完成后', '展开途中', '划选松手后']) {
    final partial = mode == '展开途中';
    final drag = mode == '划选松手后';
    testWidgets('一级和二级$mode整体收回，父菜单不先回弹放大', (tester) async {
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
      if (drag) {
        await gesture!.moveTo(tester.getCenter(find.text('Sort')));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        await gesture.moveTo(tester.getCenter(find.text('Child marker')));
      } else {
        await tester.tap(find.text('Sort'));
      }
      if (partial) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
      } else {
        await tester.pumpAndSettle();
      }
      final pivot = tester.getCenter(find.byKey(entryKey));
      final parent = find.text('Parent marker');
      final child = find.text('Child marker');
      final parentStart = tester.getCenter(parent) - pivot;
      final childStart = tester.getCenter(child) - pivot;
      if (drag) {
        await gesture!.up();
      } else if (partial) {
        // 子菜单还未完全展开时点击外部，同一帧关闭整组。
        await tester.tapAt(const Offset(700, 500));
      } else {
        await tester.tap(child);
      }
      await tester.pump();
      expect(
        (tester.getCenter(parent) - pivot - parentStart).distance,
        lessThan(.1),
        reason: '开始关闭不能跳到完整尺寸',
      );
      expect(
        (tester.getCenter(child) - pivot - childStart).distance,
        lessThan(.1),
      );
      var previousScale = 1.0;
      for (var elapsed = 16; elapsed <= 208; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        final parentVector = tester.getCenter(parent) - pivot;
        final childVector = tester.getCenter(child) - pivot;
        final parentScale = parentVector.dy / parentStart.dy;
        final childScale = childVector.dy / childStart.dy;
        expect(
          parentScale,
          lessThanOrEqualTo(previousScale + .001),
          reason: '一级菜单不能先放大',
        );
        expect(
          parentScale,
          closeTo(childScale, .002),
          reason: '$elapsed ms 两层必须共用整体收回进度',
        );
        expect(parentVector.dx, closeTo(parentStart.dx * parentScale, .1));
        expect(childVector.dx, closeTo(childStart.dx * parentScale, .1));
        previousScale = parentScale;
      }
      await tester.pumpAndSettle();
      expect(parent, findsNothing);
      expect(child, findsNothing);
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
