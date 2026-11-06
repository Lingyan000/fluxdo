import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../providers/app_icon_provider.dart';

/// 启动页"绘制 logo"动画组件
///
/// 入场时用主题色细线沿轮廓逐段描出 logo,随后各色块依次淡入、
/// 描边线淡出,终态与 assets 中的 SVG 完全一致(直接用 CustomPainter
/// 复刻几何,无需切换回 SVG)。绘制完成后保持光晕缓慢呼吸。
class PreheatLogo extends StatefulWidget {
  final AppIconStyle style;
  final double size;

  const PreheatLogo({super.key, required this.style, this.size = 108});

  @override
  State<PreheatLogo> createState() => _PreheatLogoState();
}

class _PreheatLogoState extends State<PreheatLogo>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    duration: const Duration(milliseconds: 2200),
    vsync: this,
  );
  late final AnimationController _glow = AnimationController(
    duration: const Duration(milliseconds: 2400),
    vsync: this,
  );

  List<_LogoShape> _shapes = const [];
  Brightness? _brightness;

  @override
  void initState() {
    super.initState();
    _entry
      ..addStatusListener((status) {
        // 绘制完成后才开始光晕呼吸
        if (status == AnimationStatus.completed) {
          _glow.repeat(reverse: true);
        }
      })
      ..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness != brightness) {
      _brightness = brightness;
      _rebuildShapes();
    }
  }

  @override
  void didUpdateWidget(covariant PreheatLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      _rebuildShapes();
    }
  }

  void _rebuildShapes() {
    _shapes = widget.style == AppIconStyle.modern
        ? _buildModernShapes(_brightness ?? Brightness.light)
        : _buildClassicShapes();
  }

  @override
  void dispose() {
    _entry.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final viewSize = widget.style == AppIconStyle.modern ? 1890.0 : 1024.0;

    return AnimatedBuilder(
      animation: Listenable.merge([_entry, _glow]),
      builder: (context, _) {
        // 光晕随填充出现而渐亮,之后跟随 _glow 缓慢呼吸
        final glowIn = _segment(_entry.value, 0.45, 1.0, Curves.easeIn);
        final breathe = Curves.easeInOutSine.transform(_glow.value);
        final glowAlpha = glowIn * (0.12 + 0.10 * breathe);
        final glowBlur = 36.0 + 16.0 * breathe;

        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: glowAlpha),
                blurRadius: glowBlur,
              ),
            ],
          ),
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: _LogoPainter(
                shapes: _shapes,
                t: _entry.value,
                strokeColor: colorScheme.primary,
                viewSize: viewSize,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 将整体进度 [t] 映射到 [start, end] 区间内的局部进度并应用曲线
double _segment(
  double t,
  double start,
  double end, [
  Curve curve = Curves.easeInOutCubic,
]) {
  return curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));
}

/// logo 的一个组成形状:填充路径 + 可选的描边路径与裁剪
class _LogoShape {
  final Path fillPath;
  final Color fill;

  /// 描边动画走的路径,可与填充轮廓不同(如经典 logo 用分界弦线)
  final Path? strokePath;

  /// 填充时的裁剪范围(经典 logo 三条色带裁剪在内圆中)
  final Path? clip;

  final double strokeStart;
  final double strokeEnd;
  final double fillStart;
  final double fillEnd;

  const _LogoShape({
    required this.fillPath,
    required this.fill,
    this.strokePath,
    this.clip,
    this.strokeStart = 0,
    this.strokeEnd = 1,
    required this.fillStart,
    required this.fillEnd,
  });
}

class _LogoPainter extends CustomPainter {
  final List<_LogoShape> shapes;
  final double t;
  final Color strokeColor;

  /// viewBox 边长,绘制时统一缩放到组件尺寸
  final double viewSize;

  /// 描边线在该进度后整体淡出
  static const double _strokeFadeStart = 0.84;

  const _LogoPainter({
    required this.shapes,
    required this.t,
    required this.strokeColor,
    required this.viewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / viewSize;
    canvas.save();
    canvas.scale(scale);

    for (final shape in shapes) {
      final fillT = _segment(
        t,
        shape.fillStart,
        shape.fillEnd,
        Curves.easeInOut,
      );
      if (fillT <= 0) continue;
      canvas.save();
      if (shape.clip != null) {
        canvas.clipPath(shape.clip!);
      }
      canvas.drawPath(
        shape.fillPath,
        Paint()..color = shape.fill.withValues(alpha: fillT),
      );
      canvas.restore();
    }

    final strokeAlpha =
        1.0 - _segment(t, _strokeFadeStart, 1.0, Curves.easeOut);
    if (strokeAlpha > 0) {
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 / scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = strokeColor.withValues(alpha: strokeAlpha);
      for (final shape in shapes) {
        final strokePath = shape.strokePath;
        if (strokePath == null) continue;
        final strokeT = _segment(
          t,
          shape.strokeStart,
          shape.strokeEnd,
          Curves.easeInOutCubic,
        );
        if (strokeT <= 0) continue;
        for (final metric in strokePath.computeMetrics()) {
          canvas.drawPath(
            metric.extractPath(0, metric.length * strokeT),
            strokePaint,
          );
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) {
    return oldDelegate.t != t ||
        oldDelegate.shapes != shapes ||
        oldDelegate.strokeColor != strokeColor;
  }
}

/// 经典 logo(assets/logo.svg):底圆 + 内圆裁剪的三条色带,viewBox 1024
List<_LogoShape> _buildClassicShapes() {
  const center = Offset(512, 512);
  const innerRadius = 421.0;

  final outerCircle = Path()
    ..addOval(Rect.fromCircle(center: center, radius: 448));
  final innerClip = Path()
    ..addOval(Rect.fromCircle(center: center, radius: innerRadius));

  // 色带分界线在内圆中的弦
  Path chord(double y) {
    final dy = y - center.dy;
    final half = math.sqrt(innerRadius * innerRadius - dy * dy);
    return Path()
      ..moveTo(center.dx - half, y)
      ..lineTo(center.dx + half, y);
  }

  Path band(double top, double height) =>
      Path()..addRect(Rect.fromLTWH(91, top, 842, height));

  return [
    _LogoShape(
      fillPath: outerCircle,
      fill: const Color(0xFFF0F0F0),
      strokePath: outerCircle,
      strokeStart: 0.0,
      strokeEnd: 0.45,
      fillStart: 0.45,
      fillEnd: 0.66,
    ),
    _LogoShape(
      fillPath: band(91, 233),
      fill: const Color(0xFF1C1C1E),
      clip: innerClip,
      strokePath: chord(324),
      strokeStart: 0.20,
      strokeEnd: 0.42,
      fillStart: 0.52,
      fillEnd: 0.72,
    ),
    _LogoShape(
      fillPath: band(324, 376),
      fill: const Color(0xFFF0F0F0),
      clip: innerClip,
      strokePath: chord(700),
      strokeStart: 0.30,
      strokeEnd: 0.52,
      fillStart: 0.58,
      fillEnd: 0.78,
    ),
    _LogoShape(
      fillPath: band(700, 233),
      fill: const Color(0xFFFFB003),
      clip: innerClip,
      fillStart: 0.64,
      fillEnd: 0.84,
    ),
  ];
}

/// modern logo(assets/logo_modern*.svg):圆 + 旗形 + 底条 + 黄色块,
/// viewBox -158 -158 1890 1890,构建后整体平移到正坐标系
List<_LogoShape> _buildModernShapes(Brightness brightness) {
  const offset = Offset(158, 158);
  final dark = brightness == Brightness.dark;
  final circleColor = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF0F0F3);
  final flagColor = dark ? const Color(0xFFF0F0F3) : const Color(0xFF1C1C1E);

  final circle = Path()
    ..addOval(Rect.fromCircle(center: const Offset(787, 787), radius: 787));

  final flag = Path()
    ..moveTo(783.34, 550.29)
    ..lineTo(413.34, 375.67)
    ..cubicTo(388.37, 363.88, 358.57, 374.57, 346.78, 399.55)
    ..cubicTo(343.63, 406.22, 342, 413.51, 342, 420.89)
    ..lineTo(342, 842)
    ..cubicTo(342, 869.62, 364.38, 892, 392, 892)
    ..lineTo(762, 892)
    ..cubicTo(789.62, 892, 812, 869.62, 812, 842)
    ..lineTo(812, 595.51)
    ..cubicTo(812, 576.16, 800.84, 558.55, 783.34, 550.29)
    ..close();

  final bar = Path()
    ..addRSuperellipse(
      RSuperellipse.fromRectAndRadius(
        const Rect.fromLTRB(342, 1022, 1232, 1232),
        const Radius.circular(50),
      ),
    );

  final accent = Path()
    ..moveTo(1013.34, 658.68)
    ..lineTo(1203.34, 748.37)
    ..cubicTo(1220.84, 756.63, 1232, 774.24, 1232, 793.59)
    ..lineTo(1232, 842)
    ..cubicTo(1232, 869.62, 1209.62, 892, 1182, 892)
    ..lineTo(992, 892)
    ..cubicTo(964.38, 892, 942, 869.62, 942, 842)
    ..lineTo(942, 703.89)
    ..cubicTo(942, 676.28, 964.38, 653.89, 992, 653.89)
    ..cubicTo(999.38, 653.89, 1006.67, 655.53, 1013.34, 658.68)
    ..close();

  _LogoShape shape(
    Path path,
    Color fill, {
    required double strokeStart,
    required double strokeEnd,
    required double fillStart,
    required double fillEnd,
  }) {
    final shifted = path.shift(offset);
    return _LogoShape(
      fillPath: shifted,
      fill: fill,
      strokePath: shifted,
      strokeStart: strokeStart,
      strokeEnd: strokeEnd,
      fillStart: fillStart,
      fillEnd: fillEnd,
    );
  }

  return [
    shape(
      circle,
      circleColor,
      strokeStart: 0.0,
      strokeEnd: 0.45,
      fillStart: 0.48,
      fillEnd: 0.68,
    ),
    shape(
      flag,
      flagColor,
      strokeStart: 0.20,
      strokeEnd: 0.50,
      fillStart: 0.56,
      fillEnd: 0.76,
    ),
    shape(
      bar,
      flagColor,
      strokeStart: 0.32,
      strokeEnd: 0.54,
      fillStart: 0.62,
      fillEnd: 0.82,
    ),
    shape(
      accent,
      const Color(0xFFFFB003),
      strokeStart: 0.42,
      strokeEnd: 0.58,
      fillStart: 0.66,
      fillEnd: 0.86,
    ),
  ];
}
