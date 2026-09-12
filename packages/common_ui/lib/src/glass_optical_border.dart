import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 色罩之后的光学轮廓：窄高光、内侧柔光与背光暗边分别绘制。
/// 不参与背景模糊，也不再被色罩冲淡。使用真实轮廓法线求光照，
/// 而非从矩形中心扫角度，长边与圆弧才能在连接点连续。
class GlassOpticalBorder extends CustomPainter {
  const GlassOpticalBorder({
    required this.radius,
    required this.isDark,
    required this.strength,
  });

  final double radius;
  final bool isDark;
  final double strength;

  @visibleForTesting
  static double illumination(Offset normal) {
    final facing = math.max(0.0, normal.dx * -.6 + normal.dy * -.8);
    final reflected = math.max(0.0, normal.dx * .6 + normal.dy * .8);
    return (.12 + .72 * math.pow(facing, 3) + .16 * math.pow(reflected, 6))
        .clamp(0.0, 1.0);
  }

  static Offset _normalAt(Offset point, Size size, double radius) {
    final p = point - size.center(Offset.zero);
    final x = p.dx.abs() - (size.width / 2 - radius);
    final y = p.dy.abs() - (size.height / 2 - radius);
    if (x > 0 || y > 0) {
      final v = Offset(math.max(x, 0) * p.dx.sign, math.max(y, 0) * p.dy.sign);
      return v.distance > 0 ? v / v.distance : Offset.zero;
    }
    return x > y ? Offset(p.dx.sign, 0) : Offset(0, p.dy.sign);
  }

  void _drawBand(
    Canvas canvas,
    Size size,
    double r, {
    required double inset,
    required double width,
    required double opacity,
    bool shadow = false,
  }) {
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    final rr = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.max(0, r - inset)),
    );
    final metric = (Path()..addRRect(rr)).computeMetrics().first;
    // 每段约3dp，顶点颜色连续插值，避免圆角高光出现分段色块。
    final segments = (metric.length / 3).ceil().clamp(32, 800);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    double alphaAt(Offset point) {
      final normal = _normalAt(point, size, r);
      final light = illumination(normal);
      final value = shadow ? (1 - light) * opacity : light * opacity;
      return (value * strength).clamp(0.0, 1.0);
    }

    // 连续三角带共用接缝顶点与颜色，避免逐段描线的端点抗锯齿
    // 叠加成虚线。颜色在相邻顶点间插值，圆角与直边保持同一法线场。
    final positions = <Offset>[];
    final colors = <Color>[];
    final indices = <int>[];
    final color = shadow ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    for (var i = 0; i <= segments; i++) {
      final distance = i == segments ? 0.0 : metric.length * i / segments;
      final tangent = metric.getTangentForOffset(distance)!;
      final p = tangent.position;
      final n = Offset(-tangent.vector.dy, tangent.vector.dx);
      positions.add(p + n * width / 2);
      positions.add(p - n * width / 2);
      final c = color.withValues(alpha: alphaAt(p));
      colors.addAll([c, c]);
      if (i < segments) {
        final v = i * 2;
        indices.addAll([v, v + 1, v + 2, v + 1, v + 3, v + 2]);
      }
    }
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
      indices: indices,
    );
    canvas.drawVertices(vertices, BlendMode.src, paint..color = Colors.white);
    vertices.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strength <= 0) return;
    final r = radius.clamp(0.0, size.shortestSide / 2);
    // 均为内侧轮廓，不让发光越过圆角形成光晕或新的合成接缝。
    _drawBand(
      canvas,
      size,
      r,
      inset: 1.8,
      width: 2.4,
      opacity: isDark ? .09 : .14,
    );
    _drawBand(
      canvas,
      size,
      r,
      inset: 1.05,
      width: .65,
      opacity: isDark ? .12 : .09,
      shadow: true,
    );
    _drawBand(
      canvas,
      size,
      r,
      inset: .45,
      width: .85,
      opacity: isDark ? .72 : .94,
    );
  }

  @override
  bool shouldRepaint(GlassOpticalBorder oldDelegate) =>
      radius != oldDelegate.radius ||
      isDark != oldDelegate.isDark ||
      strength != oldDelegate.strength;
}
