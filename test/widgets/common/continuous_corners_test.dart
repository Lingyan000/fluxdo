import 'dart:math' as math;

import 'package:common_ui/src/glass_superellipse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  test('glass curve parameters follow the native clipping contour', () {
    for (final (width, height, radius) in [
      (360.0, 132.0, 20.0),
      (300.0, 56.0, 28.0),
      (80.0, 80.0, 40.0),
      (200.0, 300.0, 12.0),
    ]) {
      final path = RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
      ).getOuterPath(Rect.fromLTWH(0, 0, width, height));
      for (final top in [true, false]) {
        final a = (top ? width : height) / 2;
        final parameters = glassSuperellipseOctant(a, radius);
        final n = parameters[0], join = parameters[1];
        final center = Offset(parameters[2], parameters[3]);
        final joinPoint = Offset(
          join,
          math.pow(1 - math.pow(join / a, n), 1 / n) * a,
        );
        final startAngle = math.atan2(
          joinPoint.dy - center.dy,
          joinPoint.dx - center.dx,
        );
        for (var i = 0; i <= 10; i++) {
          final angle = startAngle + (math.pi / 4 - startAngle) * i / 10;
          final normal = Offset(math.cos(angle), math.sin(angle));
          final q = center + normal * parameters[4];
          final c = (width - height) / 2;
          final p = top ? Offset(q.dx, q.dy - c) : Offset(q.dy + c, q.dx);
          final outward = top ? normal : Offset(normal.dy, normal.dx);
          final point = p + Offset(width / 2, height / 2);
          expect(path.contains(point - outward * .4), isTrue);
          expect(path.contains(point + outward * .4), isFalse);
        }
        for (var i = 1; i <= 20; i++) {
          final x = join * i / 20;
          final y = math.pow(1 - math.pow(x / a, n), 1 / n) * a;
          final c = (width - height) / 2;
          final p = top ? Offset(x, y - c) : Offset(y + c, x);
          final grad = Offset(
            math.pow(x / a, n - 1).toDouble(),
            math.pow(y / a, n - 1).toDouble(),
          );
          final norm = grad / grad.distance;
          final normal = top ? norm : Offset(norm.dy, norm.dx);
          final point = p + Offset(width / 2, height / 2);
          expect(path.contains(point - normal * .4), isTrue);
          expect(path.contains(point + normal * .4), isFalse);
        }
      }
    }
  });

  testWidgets('segmented cards keep their corner sizes and continuous shape', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SegmentedCardGroup(
            children: [SizedBox(height: 48), SizedBox(height: 48)],
          ),
        ),
      ),
    );
    final materials = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(SegmentedCardGroup),
            matching: find.byType(Material),
          ),
        )
        .toList();
    final first = materials.first.shape! as RoundedSuperellipseBorder;
    final last = materials.last.shape! as RoundedSuperellipseBorder;
    expect(first.borderRadius.resolve(TextDirection.ltr).topLeft.x, 20);
    expect(first.borderRadius.resolve(TextDirection.ltr).bottomLeft.x, 5);
    expect(last.borderRadius.resolve(TextDirection.ltr).topLeft.x, 5);
    expect(last.borderRadius.resolve(TextDirection.ltr).bottomLeft.x, 20);
  });
}
