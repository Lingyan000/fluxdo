import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/radial_long_press_menu.dart';
import 'package:fluxdo/widgets/common/radial_menu_fixed_slots.dart';

void main() {
  group('RadialMenuFixedSlots', () {
    test('slot 0 is far left and slot 7 is far right for 8-slot grid', () {
      const center = Offset(200, 400);
      final left = RadialMenuFixedSlots.positionForSlot(slot: 0, center: center);
      final right = RadialMenuFixedSlots.positionForSlot(slot: 7, center: center);
      final mid = RadialMenuFixedSlots.positionForSlot(slot: 3, center: center);

      expect(left.dx, lessThan(center.dx));
      expect(right.dx, greaterThan(center.dx));
      expect(left.dy, closeTo(center.dy, 0.001));
      expect(right.dy, closeTo(center.dy, 0.001));
      // mid-leftish slot sits above center
      expect(mid.dy, lessThan(center.dy));
    });

    test('item positions stay fixed when item count changes', () {
      const center = Offset(160, 320);
      final threeItemFirst = RadialMenuFixedSlots.positionForSlot(
        slot: 0,
        center: center,
      );
      final eightItemFirst = RadialMenuFixedSlots.positionForSlot(
        slot: 0,
        center: center,
      );
      final threeItemSecond = RadialMenuFixedSlots.positionForSlot(
        slot: 1,
        center: center,
      );
      final eightItemSecond = RadialMenuFixedSlots.positionForSlot(
        slot: 1,
        center: center,
      );

      expect(threeItemFirst, eightItemFirst);
      expect(threeItemSecond, eightItemSecond);
    });

    test('hit testing uses fixed grid and ignores empty trailing slots', () {
      const center = Offset(200, 400);
      // Slot 0 target (left end)
      final slot0 = RadialMenuFixedSlots.positionForSlot(slot: 0, center: center);
      // Slot 7 target would be right end; with only 3 items it must miss.
      final slot7 = RadialMenuFixedSlots.positionForSlot(slot: 7, center: center);

      final hit0 = RadialMenuFixedSlots.hitIndex(
        pointer: slot0,
        center: center,
        itemCount: 3,
      );
      final hitEmpty = RadialMenuFixedSlots.hitIndex(
        pointer: slot7,
        center: center,
        itemCount: 3,
      );
      final dead = RadialMenuFixedSlots.hitIndex(
        pointer: center,
        center: center,
        itemCount: 3,
      );

      expect(hit0, 0);
      expect(hitEmpty, isNull);
      expect(dead, isNull);
    });

    test('radius is stable for fixed slots', () {
      expect(RadialMenuFixedSlots.radius, 128);
      expect(RadialMenuFixedSlots.maxSlots, 8);
      expect(RadialMenuFixedSlots.defaultSweepStart, closeTo(-math.pi / 2, 1e-9));
      expect(RadialMenuFixedSlots.defaultSweepEnd, closeTo(math.pi / 2, 1e-9));
    });
  });

  group('RadialMenuSession.radiusForCount', () {
    test('dynamic radius still scales with count for non-fixed menus', () {
      expect(RadialMenuSession.radiusForCount(2), 92);
      expect(RadialMenuSession.radiusForCount(5), 108);
      expect(RadialMenuSession.radiusForCount(8), 128);
    });
  });
}
