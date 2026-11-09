import 'package:flutter/widgets.dart';

import 'preheat_logo_motion.g.dart';

/// 启动 logo 描线动画里的一个形状。
///
/// 数据由 tool/gen_splash_motion.dart 从 tool/splash_motion/logo_motion.json
/// 生成（见 preheat_logo_motion.g.dart）；Android 原生启动屏用同一份规格，
/// 两端逐帧同源。时间区间均为占总时长的比例。
class LogoMotionShape {
  LogoMotionShape({
    required this.id,
    this.isBody = false,
    this.fillPath,
    this.fillLight,
    this.fillDark,
    this.fillStart = 0,
    this.fillEnd = 0,
    this.strokePath,
    this.strokeStart = 0,
    this.strokeEnd = 0,
  });

  final String id;

  /// logo 圆体：退场时作为窗口，不参与部件融合
  final bool isBody;

  final Path? fillPath;
  final Color? fillLight;
  final Color? fillDark;
  final double fillStart;
  final double fillEnd;

  /// 描线走的路径，可与填充轮廓不同（如经典 logo 的色带分界弦线）
  final Path? strokePath;
  final double strokeStart;
  final double strokeEnd;

  Color? fillFor(Brightness brightness) =>
      brightness == Brightness.dark ? fillDark : fillLight;
}

class LogoMotionSpec {
  LogoMotionSpec({
    required this.viewBox,
    required this.bodyCenter,
    required this.bodyRadius,
    required this.shapes,
  });

  final Rect viewBox;

  /// logo 圆体（viewBox 坐标）
  final Offset bodyCenter;
  final double bodyRadius;

  final List<LogoMotionShape> shapes;

  /// 圆体半径占 logo 边长的比例
  double get bodyRadiusRatio => bodyRadius / viewBox.width;

  LogoMotionShape get body => shapes.firstWhere((s) => s.isBody);
}

double _segment(double t, double start, double end) {
  if (end <= start) return t >= end ? 1 : 0;
  return ((t - start) / (end - start)).clamp(0.0, 1.0);
}

/// 按规格绘制描线动画的某一帧。
///
/// 语义与 Android AnimatedVectorDrawable 一致：填色是 fillAlpha 渐变；
/// 描线是 trimPathEnd，按整条路径总长裁剪；曲线作用于各自区间。
class LogoMotionPainter extends CustomPainter {
  LogoMotionPainter({
    required this.spec,
    required this.progress,
    required this.brightness,
    this.merge = 0,
    this.cutoutCenter = Offset.zero,
    this.cutoutRadius = 0,
  });

  final LogoMotionSpec spec;

  /// 描线进度 0..1
  final double progress;
  final Brightness brightness;

  /// 退场时内部部件并入圆体的进度 0..1
  final double merge;

  /// 从 logo 上挖掉的透明圆（画布坐标），半径为 0 时不挖
  final Offset cutoutCenter;
  final double cutoutRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final viewBox = spec.viewBox;
    final scale = size.shortestSide / viewBox.width;
    canvas.save();
    if (cutoutRadius > 0) {
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect((Offset.zero & size).inflate(size.longestSide))
          ..addOval(
            Rect.fromCircle(center: cutoutCenter, radius: cutoutRadius),
          ),
      );
    }
    canvas.scale(scale);
    canvas.translate(-viewBox.left, -viewBox.top);

    final shrink = 1 - Curves.easeInCubic.transform(merge.clamp(0.0, 1.0));
    for (final shape in spec.shapes) {
      final path = shape.fillPath;
      final color = shape.fillFor(brightness);
      if (path == null || color == null) continue;
      final alpha = logoMotionFillCurve.transform(
        _segment(progress, shape.fillStart, shape.fillEnd),
      );
      if (alpha <= 0) continue;
      if (!shape.isBody && shrink <= 0) continue;
      final merging = !shape.isBody && shrink < 1;
      if (merging) {
        canvas.save();
        canvas.translate(spec.bodyCenter.dx, spec.bodyCenter.dy);
        canvas.scale(shrink);
        canvas.translate(-spec.bodyCenter.dx, -spec.bodyCenter.dy);
      }
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: alpha));
      if (merging) canvas.restore();
    }

    final strokeAlpha =
        1 -
        logoMotionStrokeFadeCurve.transform(
          _segment(
            progress,
            logoMotionStrokeFadeStart,
            logoMotionStrokeFadeEnd,
          ),
        );
    if (strokeAlpha > 0) {
      final strokeColor = brightness == Brightness.dark
          ? logoMotionStrokeDark
          : logoMotionStrokeLight;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        // viewBox 单位，随 logo 尺寸等比缩放（与原生矢量的 strokeWidth 同义）
        ..strokeWidth =
            logoMotionStrokeWidth * viewBox.width / logoMotionLogoSize
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = strokeColor.withValues(alpha: strokeAlpha);
      for (final shape in spec.shapes) {
        final path = shape.strokePath;
        if (path == null) continue;
        final t = logoMotionStrokeCurve.transform(
          _segment(progress, shape.strokeStart, shape.strokeEnd),
        );
        if (t <= 0) continue;
        canvas.drawPath(_trim(path, t), paint);
      }
    }

    canvas.restore();
  }

  /// 按整条路径（所有轮廓）总长裁剪到 [t]，同 trimPathEnd
  static Path _trim(Path path, double t) {
    if (t >= 1) return path;
    final metrics = path.computeMetrics().toList();
    var remaining = metrics.fold<double>(0, (sum, m) => sum + m.length) * t;
    final out = Path();
    for (final metric in metrics) {
      if (remaining <= 0) break;
      final len = remaining < metric.length ? remaining : metric.length;
      out.addPath(metric.extractPath(0, len), Offset.zero);
      remaining -= len;
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant LogoMotionPainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.progress != progress ||
      oldDelegate.brightness != brightness ||
      oldDelegate.merge != merge ||
      oldDelegate.cutoutCenter != cutoutCenter ||
      oldDelegate.cutoutRadius != cutoutRadius;
}
