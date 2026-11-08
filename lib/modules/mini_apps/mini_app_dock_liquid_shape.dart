import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 保留端点间距，把静止圆弧收窄到更靠近边缘的一侧。
Path insetMiniAppArc(Path path, Size size, double progress, bool right) {
  final bounds = path.getBounds();
  final scaleX = ui.lerpDouble(.68, 1, progress)!;
  final edge = 4 * (1 - progress);
  final offset = right
      ? size.width - edge - bounds.right * scaleX
      : edge - bounds.left * scaleX;
  return path.transform(
    (Matrix4.identity()
          ..translateByDouble(offset, 0, 0, 1)
          ..scaleByDouble(scaleX, 1, 1, 1))
        .storage,
  );
}

/// 拉动时空心弧收成水滴，尾部朝向拉出的位置；停靠时沿同一路径融回。
class MiniAppDockLiquidShape extends ShapeBorder {
  MiniAppDockLiquidShape({
    required Path arc,
    required Size size,
    required double amount,
    required Offset tail,
  }) : outline = _morph(arc, _drop(size, tail), amount);

  const MiniAppDockLiquidShape.outline(this.outline);
  final Path outline;

  static Path _drop(Size size, Offset tail) {
    final length = tail.distance;
    final direction = length < .01 ? const Offset(1, 0) : tail / length;
    const r = 12.5;
    final stretch = math.min(8.5, length * .4);
    // 起点与圆弧一致，从顶部沿左边走，避免变形时轮廓扭转。
    final points = <Offset>[];
    for (var i = 0; i < 80; i++) {
      final angle = -math.pi / 2 - math.pi * 2 * i / 80;
      final normal = Offset(math.cos(angle), math.sin(angle));
      final towardTail = math.max(
        0.0,
        normal.dx * direction.dx + normal.dy * direction.dy,
      );
      final radius = r + stretch * math.pow(towardTail, 8);
      points.add(Offset(size.width / 2, size.height / 2) + normal * radius);
    }
    return _smooth(points);
  }

  static Path _morph(Path from, Path to, double amount) {
    if (amount <= 0) return from;
    if (amount >= 1) return to;
    final a = from.computeMetrics().first;
    final b = to.computeMetrics().first;
    return _smooth(
      List.generate(
        80,
        (i) => Offset.lerp(
          a.getTangentForOffset(a.length * i / 80)!.position,
          b.getTangentForOffset(b.length * i / 80)!.position,
          Curves.easeInOut.transform(amount),
        )!,
      ),
    );
  }

  static Path _smooth(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    final n = points.length;
    for (var i = 0; i < n; i++) {
      final a = points[(i - 1 + n) % n], b = points[i];
      final c = points[(i + 1) % n], d = points[(i + 2) % n];
      final first = b + (c - a) / 6;
      final second = c - (d - b) / 6;
      path.cubicTo(first.dx, first.dy, second.dx, second.dy, c.dx, c.dy);
    }
    return path..close();
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  ShapeBorder scale(double t) => this;
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      outline.shift(rect.topLeft);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}
}
