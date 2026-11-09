import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../providers/app_icon_provider.dart';
import 'preheat_logo_motion.dart';
import 'preheat_logo_motion.g.dart';

/// 启动页 logo
///
/// 描线动画由 [entry] 驱动，几何与时间线来自生成的规格（与 Android 原生
/// 启动屏同源）。logo 完整呈现（[shown]）后主题色光晕淡入并缓慢呼吸；
/// 退场时 [merge] 驱动内部部件并入圆体，光晕随之淡出。[notch] 给出时，
/// 在 logo 上挖出透明缺口（状态角标停靠处），缺口里不透出光晕。
class PreheatLogo extends StatefulWidget {
  final AppIconStyle style;
  final Animation<double> entry;

  /// logo 已完整呈现给用户（描线完成且原生启动屏已撤下）
  final ValueListenable<bool> shown;
  final Animation<double>? merge;

  /// 缺口半径（logo 边长归一化），0 为不挖
  final Animation<double>? notch;

  /// 缺口中心（相对 logo 中心，logo 边长归一化）
  final Offset notchCenter;
  final double size;

  const PreheatLogo({
    super.key,
    required this.style,
    required this.entry,
    required this.shown,
    this.merge,
    this.notch,
    this.notchCenter = Offset.zero,
    this.size = logoMotionLogoSize,
  });

  static LogoMotionSpec specOf(AppIconStyle style) =>
      style == AppIconStyle.modern ? modernLogoMotion : classicLogoMotion;

  @override
  State<PreheatLogo> createState() => _PreheatLogoState();
}

class _PreheatLogoState extends State<PreheatLogo>
    with TickerProviderStateMixin {
  late final AnimationController _glowIn = AnimationController(
    duration: const Duration(milliseconds: 600),
    vsync: this,
  );
  late final AnimationController _glow = AnimationController(
    duration: const Duration(milliseconds: 2400),
    vsync: this,
  );
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    widget.shown.addListener(_onShown);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _onShown();
  }

  @override
  void didUpdateWidget(covariant PreheatLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shown != widget.shown) {
      oldWidget.shown.removeListener(_onShown);
      widget.shown.addListener(_onShown);
      _onShown();
    }
  }

  // logo 完整呈现后才开始光晕：原生启动屏没有光晕，各平台都在此之后出现
  void _onShown() {
    if (!widget.shown.value) {
      _glowIn.value = 0;
      _glow.value = 0;
    } else if (_reduceMotion) {
      // 停在当前明度，切换系统设置时也不会跳到另一个呼吸阶段。
      _glow.stop();
      _glowIn.value = 1;
    } else {
      _glowIn.forward();
      if (!_glow.isAnimating) _glow.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    widget.shown.removeListener(_onShown);
    _glowIn.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = PreheatLogo.specOf(widget.style);
    final merge = widget.merge ?? kAlwaysDismissedAnimation;
    final notch = widget.notch ?? kAlwaysDismissedAnimation;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.entry, merge, notch, _glowIn, _glow]),
      builder: (context, _) {
        final breathe = Curves.easeInOutSine.transform(_glow.value);
        final glowAlpha =
            Curves.easeIn.transform(_glowIn.value) *
            (1 - merge.value) *
            (0.12 + 0.10 * breathe);

        return CustomPaint(
          painter: _GlowPainter(
            color: theme.colorScheme.primary.withValues(alpha: glowAlpha),
            blurRadius: 36.0 + 16.0 * breathe,
            bodyRadius: spec.bodyRadiusRatio * widget.size,
          ),
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: LogoMotionPainter(
                spec: spec,
                progress: widget.entry.value,
                brightness: theme.brightness,
                merge: merge.value,
                cutoutCenter:
                    Offset(widget.size / 2, widget.size / 2) +
                    widget.notchCenter * widget.size,
                cutoutRadius: notch.value * widget.size,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// logo 光晕：主题色圆形柔光，只画在圆体之外。
///
/// 圆体不透明，本就盖住其下的光晕；只画在外面是为了 logo 挖出透明缺口时，
/// 缺口里不透出光晕。裁剪圆比圆体小 1px，避免圆体抗锯齿边缘露缝。
class _GlowPainter extends CustomPainter {
  _GlowPainter({
    required this.color,
    required this.blurRadius,
    required this.bodyRadius,
  });

  final Color color;
  final double blurRadius;
  final double bodyRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a <= 0) return;
    final center = size.center(Offset.zero);
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(size.longestSide + blurRadius))
        ..addOval(Rect.fromCircle(center: center, radius: bodyRadius - 1)),
    );
    canvas.drawCircle(
      center,
      size.shortestSide / 2,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          Shadow.convertRadiusToSigma(blurRadius),
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.blurRadius != blurRadius ||
      oldDelegate.bodyRadius != bodyRadius;
}
