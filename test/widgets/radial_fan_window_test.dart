import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/radial_long_press_menu.dart';

void main() {
  const screen = Size(360, 780);
  const padding = EdgeInsets.only(top: 44, bottom: 34);
  // 放大态项半径 29 + 边距 8
  const itemReach = 37.0;

  List<Offset> layout({
    required int count,
    required Offset anchor,
    RadialMenuDirection direction = RadialMenuDirection.up,
  }) {
    final w = solveRadialFanWindow(
      itemCount: count,
      anchorX: anchor.dx,
      screenWidth: screen.width,
      anchorY: anchor.dy,
      screenHeight: screen.height,
      safePadding: padding,
      direction: direction,
    );
    final up = direction == RadialMenuDirection.up;
    return [
      for (var i = 0; i < count; i++)
        () {
          final phi = count == 1
              ? (w.sweepStart + w.sweepEnd) / 2
              : w.sweepStart + i * (w.sweepEnd - w.sweepStart) / (count - 1);
          return Offset(
            anchor.dx + w.radius * math.sin(phi),
            anchor.dy + (up ? -1 : 1) * w.radius * math.cos(phi),
          );
        }(),
    ];
  }

  void expectFits(List<Offset> items, String label) {
    for (final p in items) {
      expect(
        p.dx,
        inInclusiveRange(itemReach - 0.5, screen.width - itemReach + 0.5),
        reason: '$label 横向越界: $p',
      );
      expect(
        p.dy,
        inInclusiveRange(
          padding.top + itemReach - 0.5,
          screen.height - padding.bottom - itemReach + 0.5,
        ),
        reason: '$label 纵向越界: $p',
      );
    }
    for (var i = 1; i < items.length; i++) {
      expect(
        (items[i] - items[i - 1]).distance,
        greaterThanOrEqualTo(48),
        reason: '$label 第 $i 项与前一项重叠',
      );
    }
  }

  // 底栏顶边：屏幕底 - 安全区 - 栏高
  const barTop = 780 - 34 - 58.0;

  test('底栏任意位置长按，1~8 项都完整落在屏幕内且不重叠', () {
    for (final x in const <double>[20, 48, 90, 180, 270, 312, 340]) {
      for (var count = 1; count <= 8; count++) {
        expectFits(
          layout(count: count, anchor: Offset(x, barTop)),
          'x=$x n=$count',
        );
      }
    }
  });

  test('贴近屏幕顶部向下展开时同样完整', () {
    for (final x in const <double>[20, 180, 340]) {
      for (var count = 1; count <= 8; count++) {
        expectFits(
          layout(
            count: count,
            anchor: Offset(x, 120),
            direction: RadialMenuDirection.down,
          ),
          'down x=$x n=$count',
        );
      }
    }
  });

  test('屏幕中部仍是标准半圆', () {
    final w = solveRadialFanWindow(
      itemCount: 6,
      anchorX: 180,
      screenWidth: screen.width,
      anchorY: 400,
      screenHeight: screen.height,
      safePadding: padding,
    );
    expect(w.sweepStart, closeTo(-math.pi / 2, 1e-9));
    expect(w.sweepEnd, closeTo(math.pi / 2, 1e-9));
    expect(w.radius, RadialMenuSession.radiusForCount(6));
  });
}
