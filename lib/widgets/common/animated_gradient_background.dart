import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';

/// 流动多彩渐变背景动画组件
///
/// 创建类似"极光"或"流体"的效果：
/// - 多层叠加的渐变色块
/// - 每层以不同速度和方向流动
/// - 颜色柔和过渡
/// - 整体呈现梦幻、高级的视觉感
class AnimatedGradientBackground extends StatefulWidget {
  /// 子组件，显示在渐变背景之上
  final Widget? child;

  /// 自定义颜色列表，至少需要 5 个颜色
  /// 如果不提供，将使用默认的颜色
  final List<Color>? colors;

  const AnimatedGradientBackground({
    super.key,
    this.child,
    this.colors,
  });

  @override
  State<AnimatedGradientBackground> createState() =>
      _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState extends State<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  // 使用单个 AnimationController，通过相位偏移创造不同运动
  late AnimationController _controller;

  // 默认颜色方案
  static const _defaultColors = [
    Color(0xFF0f0c29), // 深紫底色
    Color(0xFF6366f1), // 靛蓝色
    Color(0xFF8b5cf6), // 紫色
    Color(0xFFec4899), // 粉色
    Color(0xFF06b6d4), // 青色
  ];

  List<Color> get _colors => widget.colors ?? _defaultColors;

  @override
  void initState() {
    super.initState();
    // 单个控制器，周期 20 秒，确保循环完全平滑
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _GradientPainter(
              animValue: _controller.value,
              colors: _colors,
            ),
            isComplex: true,
            willChange: true,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// 渐变绘制器
class _GradientPainter extends CustomPainter {
  final double animValue;
  final List<Color> colors;

  // 预定义的色块配置，速度倍数必须是整数才能保证无缝循环
  static const _blobConfigs = [
    _BlobConfig(speedMultiplier: 1, phaseOffset: 0.0, colorIndex: 1, radius: 1.2, opacity: 0.7, baseX: 0.3, baseY: 0.2, moveX: 0.4, moveY: 0.3),
    _BlobConfig(speedMultiplier: 2, phaseOffset: 0.25, colorIndex: 2, radius: 1.0, opacity: 0.6, baseX: 0.7, baseY: 0.6, moveX: 0.3, moveY: 0.4),
    _BlobConfig(speedMultiplier: 3, phaseOffset: 0.5, colorIndex: 3, radius: 0.9, opacity: 0.5, baseX: 0.2, baseY: 0.8, moveX: 0.35, moveY: 0.25),
    _BlobConfig(speedMultiplier: 2, phaseOffset: 0.75, colorIndex: 4, radius: 0.8, opacity: 0.5, baseX: 0.8, baseY: 0.2, moveX: 0.25, moveY: 0.35),
  ];

  static const _highlightConfigs = [
    _BlobConfig(speedMultiplier: 2, phaseOffset: 0.33, colorIndex: 1, radius: 0.5, opacity: 0.4, baseX: 0.5, baseY: 0.4, moveX: 0.2, moveY: 0.2),
    _BlobConfig(speedMultiplier: 1, phaseOffset: 0.67, colorIndex: 3, radius: 0.4, opacity: 0.35, baseX: 0.3, baseY: 0.6, moveX: 0.2, moveY: 0.2),
  ];

  _GradientPainter({
    required this.animValue,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1. 绘制渐变底色
    final baseGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        colors[0],
        Color.lerp(colors[0], colors[1], 0.3)!,
      ],
    );
    canvas.drawRect(rect, Paint()..shader = baseGradient.createShader(rect));

    // 2. 绘制流动的色块
    for (final config in _blobConfigs) {
      _drawColorBlob(canvas, rect, config);
    }

    // 3. 绘制高光
    for (final config in _highlightConfigs) {
      _drawHighlight(canvas, rect, config);
    }
  }

  /// 绘制流动的颜色块
  void _drawColorBlob(Canvas canvas, Rect rect, _BlobConfig config) {
    // 计算当前相位：基础动画值 * 速度倍数 + 相位偏移，取模确保循环
    final phase = (animValue * config.speedMultiplier + config.phaseOffset) % 1.0;
    final angle = phase * 2 * math.pi;

    final centerX = config.baseX + math.sin(angle) * config.moveX;
    final centerY = config.baseY + math.cos(angle) * config.moveY;

    final gradient = RadialGradient(
      center: Alignment(centerX * 2 - 1, centerY * 2 - 1),
      radius: config.radius,
      colors: [
        colors[config.colorIndex].withValues(alpha: config.opacity),
        colors[config.colorIndex].withValues(alpha: config.opacity * 0.5),
        colors[config.colorIndex].withValues(alpha: 0),
      ],
      stops: const [0.0, 0.4, 1.0],
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = gradient.createShader(rect)
        ..blendMode = BlendMode.plus,
    );
  }

  /// 绘制高光
  void _drawHighlight(Canvas canvas, Rect rect, _BlobConfig config) {
    final phase = (animValue * config.speedMultiplier + config.phaseOffset) % 1.0;
    final angle = phase * 2 * math.pi;

    final centerX = config.baseX + math.sin(angle) * config.moveX;
    final centerY = config.baseY + math.cos(angle + math.pi / 3) * config.moveY;

    final gradient = RadialGradient(
      center: Alignment(centerX * 2 - 1, centerY * 2 - 1),
      radius: config.radius,
      colors: [
        colors[config.colorIndex].withValues(alpha: config.opacity),
        colors[config.colorIndex].withValues(alpha: 0),
      ],
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = gradient.createShader(rect)
        ..blendMode = BlendMode.plus,
    );
  }

  @override
  bool shouldRepaint(covariant _GradientPainter oldDelegate) {
    return animValue != oldDelegate.animValue;
  }
}

/// 色块配置
class _BlobConfig {
  final int speedMultiplier;    // 速度倍数（整数，确保无缝循环）
  final double phaseOffset;     // 相位偏移 (0-1)
  final int colorIndex;         // 颜色索引
  final double radius;          // 半径
  final double opacity;         // 透明度
  final double baseX;           // 基准 X 位置 (0-1)
  final double baseY;           // 基准 Y 位置 (0-1)
  final double moveX;           // X 方向移动幅度
  final double moveY;           // Y 方向移动幅度

  const _BlobConfig({
    required this.speedMultiplier,
    required this.phaseOffset,
    required this.colorIndex,
    required this.radius,
    required this.opacity,
    required this.baseX,
    required this.baseY,
    required this.moveX,
    required this.moveY,
  });
}
