import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从导航外壳原样提取，保持 05294df6 的 SweepGradient 方向性高光。
class GlassEdgePainter extends CustomPainter {
  const GlassEdgePainter({required this.radius, required this.isDark});

  final double radius;
  final bool isDark;

  /// 0.5：与 shader 光学边缘（0.5dp）同宽
  static const double _width = 0.5;

  /// 光源方向角（弧度）。atan2(-0.82, -0.58) ≈ -125.3°，即左上方，
  /// 与 glass_surface.frag 的 lightDirection 同源。
  static final double _lightAngle = math.atan2(-0.82, -0.58);

  /// 迎光峰值与背光保底。深色下白边必须收得很狠，否则像描了荧光笔。
  double get _peakAlpha => isDark ? 0.188 : 0.46;
  double get _baseAlpha => isDark ? 0.042 : 0.19;

  /// 绕一圈采样出方向性高光曲线。段数取 24：低于 16 在长边上能看出
  /// 折线，再高对观感无增益。
  List<Color> _sweepColors() {
    const segments = 24;
    // 玻璃边缘是反光，两种亮度模式都用白 —— 浅色下用黑边会变成线框，
    // 失去"被照亮"的观感。
    const base = Color(0xFFFFFFFF);
    return [
      for (var i = 0; i <= segments; i++)
        base.withValues(alpha: _alphaAt(i / segments * 2 * math.pi)),
    ];
  }

  /// 单侧余弦三次方：与 shader 的 pow(max(dot,0), 3.0) 等价。
  /// 三次方让高光集中在迎光象限，一次方会糊成整圈都亮。
  double _alphaAt(double angle) {
    final d = math.cos(angle - _lightAngle);
    final directional = d <= 0 ? 0.0 : d * d * d;
    return _baseAlpha + (_peakAlpha - _baseAlpha) * directional;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 描边以路径为中心线各占一半，内缩半个宽度才能整条落在胶囊内
    final rect = Offset.zero & size;
    final inner = rect.deflate(_width / 2);
    final rrect = RRect.fromRectAndRadius(
      inner,
      Radius.circular(radius - _width / 2),
    );
    final colors = _sweepColors();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _width
      ..shader = ui.Gradient.sweep(inner.center, colors, [
        for (var i = 0; i < colors.length; i++) i / (colors.length - 1),
      ]);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(GlassEdgePainter old) =>
      old.radius != radius || old.isDark != isDark;
}
