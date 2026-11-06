// Geometry adapted from Flutter's impeller/geometry/round_superellipse_param.cc.
// Copyright 2013 The Flutter Authors. BSD-3-Clause license.
import 'dart:math' as math;

/// Parameters of one octant of Flutter's rounded superellipse, in physical pixels.
List<double> glassSuperellipseOctant(double a, double radius) {
  const table = [
    (2.00000000, 1.13276676),
    (2.18349805, 1.20311921),
    (2.33888662, 1.28698796),
    (2.48660575, 1.36351941),
    (2.62226596, 1.44717976),
    (2.75148990, 1.53385819),
    (3.36298265, 1.98288283),
    (4.08649929, 2.23811846),
    (4.85481134, 2.47563463),
    (5.62945551, 2.72948597),
    (6.43023796, 2.98020421),
  ];
  if (radius <= 0 || a <= 0) return [0, 0, 0, 0, 0];
  final ratio = math.max(2.0, 2 * a / radius);
  double n, k;
  if (ratio > 5) {
    n = table.last.$1 + 1.559599389 * (ratio - 5);
    k = table.last.$2 + .522807185 * (ratio - 5);
  } else {
    final steps = ratio < 2.5 ? (ratio - 2) * 10 : (ratio - 2.5) * 2 + 5;
    final index = steps.floor().clamp(0, table.length - 2);
    final t = steps - index;
    n = table[index].$1 * (1 - t) + table[index + 1].$1 * t;
    k = table[index].$2 * (1 - t) + table[index + 1].$2 * t;
  }
  final x = (1 - 1 / k) * a;
  final y = math.pow(1 - math.pow(x / a, n), 1 / n) * a;
  final tangent = math.pow(x / y, n - 1);
  final d = (x - tangent * y) / (1 - tangent);
  final gap = .29289321881 * radius;
  final r = (a - d - gap) * math.sqrt2;
  final mx = a - gap;
  final dx = mx - x, dy = mx - y;
  final length = math.sqrt(dx * dx + dy * dy);
  final distance = math.sqrt(math.max(0, r * r - length * length / 4));
  return [
    n,
    x,
    (x + mx) / 2 + dy / length * distance,
    (y + mx) / 2 - dx / length * distance,
    r,
  ];
}
