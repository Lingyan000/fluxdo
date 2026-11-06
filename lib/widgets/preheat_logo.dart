import 'package:flutter/material.dart';

import '../providers/app_icon_provider.dart';

/// 启动页 logo
///
/// 首帧即完整静态 logo,与原生启动屏(Android 13+ 按图标登记的启动屏主题)
/// 等大同位,接管时无跳变;之后主题色光晕淡入并缓慢呼吸,表示仍在加载。
/// 直接用 CustomPainter 复刻 assets 中 SVG 的几何。
class PreheatLogo extends StatefulWidget {
  final AppIconStyle style;
  final double size;

  const PreheatLogo({super.key, required this.style, this.size = 108});

  @override
  State<PreheatLogo> createState() => _PreheatLogoState();
}

class _PreheatLogoState extends State<PreheatLogo>
    with TickerProviderStateMixin {
  late final AnimationController _glowIn = AnimationController(
    duration: const Duration(milliseconds: 900),
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
    // 原生启动屏没有光晕,首帧不带光晕,接管后再淡入
    _glowIn.forward();
    _glow.repeat(reverse: true);
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
    _glowIn.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final viewSize = widget.style == AppIconStyle.modern ? 1890.0 : 1024.0;

    return AnimatedBuilder(
      animation: Listenable.merge([_glowIn, _glow]),
      // logo 本体静态,隔离在 RepaintBoundary 里不随光晕重绘
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _LogoPainter(shapes: _shapes, viewSize: viewSize),
        ),
      ),
      builder: (context, child) {
        final glowIn = Curves.easeIn.transform(_glowIn.value);
        final breathe = Curves.easeInOutSine.transform(_glow.value);
        final glowAlpha = glowIn * (0.12 + 0.10 * breathe);
        final glowBlur = 36.0 + 16.0 * breathe;

        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: glowAlpha),
                blurRadius: glowBlur,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}

/// logo 的一个组成形状:填充路径 + 可选裁剪
class _LogoShape {
  final Path fillPath;
  final Color fill;

  /// 填充时的裁剪范围(经典 logo 三条色带裁剪在内圆中)
  final Path? clip;

  const _LogoShape({required this.fillPath, required this.fill, this.clip});
}

class _LogoPainter extends CustomPainter {
  final List<_LogoShape> shapes;

  /// viewBox 边长,绘制时统一缩放到组件尺寸
  final double viewSize;

  const _LogoPainter({required this.shapes, required this.viewSize});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / viewSize;
    canvas.save();
    canvas.scale(scale);

    for (final shape in shapes) {
      canvas.save();
      if (shape.clip != null) {
        canvas.clipPath(shape.clip!);
      }
      canvas.drawPath(shape.fillPath, Paint()..color = shape.fill);
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) {
    return oldDelegate.shapes != shapes || oldDelegate.viewSize != viewSize;
  }
}

/// 经典 logo(assets/logo.svg):底圆 + 内圆裁剪的上下两条色带,viewBox 1024
List<_LogoShape> _buildClassicShapes() {
  const center = Offset(512, 512);

  final outerCircle = Path()
    ..addOval(Rect.fromCircle(center: center, radius: 448));
  final innerClip = Path()
    ..addOval(Rect.fromCircle(center: center, radius: 421));

  Path band(double top, double height) =>
      Path()..addRect(Rect.fromLTWH(91, top, 842, height));

  return [
    _LogoShape(fillPath: outerCircle, fill: const Color(0xFFF0F0F0)),
    _LogoShape(
      fillPath: band(91, 233),
      fill: const Color(0xFF1C1C1E),
      clip: innerClip,
    ),
    _LogoShape(
      fillPath: band(700, 233),
      fill: const Color(0xFFFFB003),
      clip: innerClip,
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

  return [
    _LogoShape(fillPath: circle.shift(offset), fill: circleColor),
    _LogoShape(fillPath: flag.shift(offset), fill: flagColor),
    _LogoShape(fillPath: bar.shift(offset), fill: flagColor),
    _LogoShape(fillPath: accent.shift(offset), fill: const Color(0xFFFFB003)),
  ];
}
