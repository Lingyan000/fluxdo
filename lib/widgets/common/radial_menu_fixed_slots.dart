import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'radial_long_press_menu.dart';

/// Fixed-slot semicircle geometry for the progress-pill long-press menu.
///
/// Why fixed slots:
/// - The menu always has up to [maxSlots] positions.
/// - Item *i* always lands on slot *i*, even when fewer than 8 actions are
///   selected. This keeps muscle memory stable and makes the settings preview
///   match the runtime menu left-to-right.
///
/// Coordinate system matches [RadialMenuSession]:
/// - polar offset φ = 0 points straight into the open direction
/// - left is negative, right is positive
/// - default window is the full upper/lower semicircle [-π/2, π/2]
class RadialMenuFixedSlots {
  RadialMenuFixedSlots._();

  /// Maximum number of actions / fixed arc positions.
  static const int maxSlots = 8;

  /// Radius sized for a full 8-item arc (matches former radiusForCount(8)).
  static const double radius = 128.0;

  static const double defaultSweepStart = -math.pi / 2;
  static const double defaultSweepEnd = math.pi / 2;

  /// Minimum pointer distance from center before a slot can highlight.
  static const double deadZoneDistance = 18.0;

  static double slotStep({
    double sweepStart = defaultSweepStart,
    double sweepEnd = defaultSweepEnd,
    int slotCount = maxSlots,
  }) {
    if (slotCount <= 1) return 0;
    return (sweepEnd - sweepStart) / (slotCount - 1);
  }

  /// Polar offset φ for a fixed slot index in `[0, slotCount)`.
  static double phiForSlot(
    int slot, {
    double sweepStart = defaultSweepStart,
    double sweepEnd = defaultSweepEnd,
    int slotCount = maxSlots,
  }) {
    if (slotCount <= 1) return (sweepStart + sweepEnd) / 2;
    final clamped = slot.clamp(0, slotCount - 1);
    return sweepStart + clamped * slotStep(
      sweepStart: sweepStart,
      sweepEnd: sweepEnd,
      slotCount: slotCount,
    );
  }

  /// Screen-space target for [slot] around [center].
  static Offset positionForSlot({
    required int slot,
    required Offset center,
    RadialMenuDirection direction = RadialMenuDirection.up,
    double radius = RadialMenuFixedSlots.radius,
    double sweepStart = defaultSweepStart,
    double sweepEnd = defaultSweepEnd,
    int slotCount = maxSlots,
  }) {
    final phi = phiForSlot(
      slot,
      sweepStart: sweepStart,
      sweepEnd: sweepEnd,
      slotCount: slotCount,
    );
    final up = direction == RadialMenuDirection.up;
    // Inverse of the φ mapping used by hit-testing:
    // up: angle = φ - π/2; down: angle = π/2 - φ
    final angle = up ? phi - math.pi / 2 : math.pi / 2 - phi;
    return Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
  }

  /// Map a global pointer to an occupied item index using the fixed slot grid.
  ///
  /// Returns `null` when the pointer is in a dead zone, lands on an empty
  /// trailing slot, or is clearly behind the fan.
  static int? hitIndex({
    required Offset pointer,
    required Offset center,
    required int itemCount,
    Rect? pressArea,
    RadialMenuDirection direction = RadialMenuDirection.up,
    double radius = RadialMenuFixedSlots.radius,
    double sweepStart = defaultSweepStart,
    double sweepEnd = defaultSweepEnd,
    int slotCount = maxSlots,
  }) {
    if (itemCount <= 0) return null;

    final dx = pointer.dx - center.dx;
    final dy = pointer.dy - center.dy;
    final distance = math.sqrt(dx * dx + dy * dy);

    final up = direction == RadialMenuDirection.up;
    final angle = math.atan2(dy, dx);
    final phi = up
        ? _wrapAngle(angle + math.pi / 2)
        : _wrapAngle(math.pi / 2 - angle);

    final mid = (sweepStart + sweepEnd) / 2;
    final offMid = (phi - mid).abs();
    final halfSweep = (sweepEnd - sweepStart) / 2;
    final deadBeyond = math.max(halfSweep + 0.35, math.pi / 2);

    // Press-area dead zone only while the finger is still near the origin.
    // End slots sit near the horizontal line; treating the whole pill as a
    // permanent dead zone forced users to drag upward before left/right
    // items would highlight.
    final onPressArea =
        pressArea != null && pressArea.inflate(6).contains(pointer);
    final stuckOnOrigin =
        distance < deadZoneDistance ||
        (onPressArea && distance < radius * 0.5);
    if (stuckOnOrigin || offMid > deadBeyond) {
      return null;
    }

    if (slotCount <= 1) return 0;
    final step = slotStep(
      sweepStart: sweepStart,
      sweepEnd: sweepEnd,
      slotCount: slotCount,
    );
    if (step <= 1e-6) return 0;

    final slot = ((phi - sweepStart) / step).round().clamp(0, slotCount - 1);
    if (slot >= itemCount) return null;
    return slot;
  }
}

double _wrapAngle(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) r -= 2 * math.pi;
  if (r <= -math.pi) r += 2 * math.pi;
  return r;
}
