import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
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
      expect(mid.dy, lessThan(center.dy));
    });

    test('end pits sit on true left/right of pill center (fan origin)', () {
      // Runtime and settings both pass the stadium visual center as fan origin.
      // End pits must share that Y so they read as 正左 / 正右 of the middle pill.
      const pillCenter = Offset(160, 520);
      final endLeft = RadialMenuFixedSlots.positionForSlot(slot: 0, center: pillCenter);
      final endRight = RadialMenuFixedSlots.positionForSlot(slot: 7, center: pillCenter);
      final topish = RadialMenuFixedSlots.positionForSlot(slot: 3, center: pillCenter);
      final nearTopLeft = RadialMenuFixedSlots.positionForSlot(slot: 1, center: pillCenter);

      expect(endLeft.dx, closeTo(pillCenter.dx - RadialMenuFixedSlots.radius, 0.001));
      expect(endRight.dx, closeTo(pillCenter.dx + RadialMenuFixedSlots.radius, 0.001));
      expect(endLeft.dy, closeTo(pillCenter.dy, 0.001));
      expect(endRight.dy, closeTo(pillCenter.dy, 0.001));
      expect(topish.dy, lessThan(pillCenter.dy));
      expect(nearTopLeft.dy, lessThan(pillCenter.dy));
      // Intermediate pits stay strictly inside the end span.
      expect(nearTopLeft.dx, greaterThan(endLeft.dx));
      expect(nearTopLeft.dx, lessThan(pillCenter.dx));
    });

    test('slot positions stay fixed regardless of occupancy', () {
      const center = Offset(160, 320);
      final slot0 = RadialMenuFixedSlots.positionForSlot(slot: 0, center: center);
      final slot7 = RadialMenuFixedSlots.positionForSlot(slot: 7, center: center);

      expect(slot0.dx, lessThan(center.dx));
      expect(slot7.dx, greaterThan(center.dx));
      // same geometry whether 1 or 8 items would be occupied
      expect(
        RadialMenuFixedSlots.positionForSlot(slot: 0, center: center),
        slot0,
      );
    });

    test('hit testing uses fixed grid and ignores empty pits', () {
      const center = Offset(200, 400);
      final slot0 = RadialMenuFixedSlots.positionForSlot(slot: 0, center: center);
      final slot7 = RadialMenuFixedSlots.positionForSlot(slot: 7, center: center);

      // Sparse occupancy: only pits 0 and 3 filled.
      final occupied = {0, 3};

      final hit0 = RadialMenuFixedSlots.hitIndex(
        pointer: slot0,
        center: center,
        occupiedSlots: occupied,
      );
      final hitEmpty = RadialMenuFixedSlots.hitIndex(
        pointer: slot7,
        center: center,
        occupiedSlots: occupied,
      );
      final dead = RadialMenuFixedSlots.hitIndex(
        pointer: center,
        center: center,
        occupiedSlots: occupied,
      );
      final nearestEmpty = RadialMenuFixedSlots.nearestSlot(
        pointer: slot7,
        center: center,
      );

      expect(hit0, 0);
      expect(hitEmpty, isNull);
      expect(dead, isNull);
      expect(nearestEmpty, 7);
    });

    test('radius is stable for fixed slots', () {
      expect(RadialMenuFixedSlots.radius, 128);
      expect(RadialMenuFixedSlots.maxSlots, 8);
      expect(RadialMenuFixedSlots.defaultSweepStart, closeTo(-math.pi / 2, 1e-9));
      expect(RadialMenuFixedSlots.defaultSweepEnd, closeTo(math.pi / 2, 1e-9));
    });
  });

  group('normalizeProgressGestureMenuSlots', () {
    test('keeps empty pits and does not pack left', () {
      final sparse = normalizeProgressGestureMenuSlots([
        ProgressGestureAction.openTimeline,
        null,
        null,
        ProgressGestureAction.reply,
        null,
        null,
        null,
        ProgressGestureAction.share,
      ]);

      expect(sparse.length, 8);
      expect(sparse[0], ProgressGestureAction.openTimeline);
      expect(sparse[1], isNull);
      expect(sparse[3], ProgressGestureAction.reply);
      expect(sparse[7], ProgressGestureAction.share);
      expect(progressGestureMenuFilledCount(sparse), 3);
    });

    test('dedupes and pads to 8', () {
      final n = normalizeProgressGestureMenuSlots([
        ProgressGestureAction.reply,
        ProgressGestureAction.reply,
        ProgressGestureAction.share,
      ]);
      expect(n.length, 8);
      expect(n[0], ProgressGestureAction.reply);
      expect(n[1], isNull); // duplicate becomes empty pit, not re-packed
      expect(n[2], ProgressGestureAction.share);
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
