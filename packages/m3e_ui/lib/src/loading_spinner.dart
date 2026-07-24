import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

/// Material 3 Expressive LoadingIndicator(不定态)的 1:1 复刻。
///
/// 规格与动画节奏逐项对照 Compose material3 的 LoadingIndicator.kt:
/// - 7 个 MaterialShapes 循环 morph:
///   SoftBurst → Cookie9Sided → Pentagon → Pill → Sunny → Cookie4Sided → Oval → 闭环;
/// - 每 650ms 触发一次 morph,弹簧 spring(dampingRatio 0.6, stiffness 200,
///   visibilityThreshold 0.1),约 298ms 收敛后停在终点等待下个周期
///   (组件专用规格,非 [M3eMotion] 六档);
/// - 每次 morph 完成后形状指针步进,叠加 90° 步进旋转(初始 90°);
/// - 全局旋转 4666ms/圈,线性,与 morph 的 progress*90° 弹性旋转叠加;
/// - 形状缩放按"动画全程最大回转半径"精确计算,保证任意帧不画出 size 之外;
///   与规格的唯一偏差是不保留 38/48 的容器留白(调用方把 size 当可见尺寸,
///   详见 _Md3LoadingGeometry.scaleFactor)。
class LoadingSpinner extends StatefulWidget {
  final Color? color;
  final double size;

  const LoadingSpinner({super.key, this.color, this.size = 48});

  @override
  State<LoadingSpinner> createState() => _LoadingSpinnerState();
}

class _LoadingSpinnerState extends State<LoadingSpinner>
    with TickerProviderStateMixin {
  // 对应 Compose 的 MorphIntervalMillis 与 GlobalRotationDurationMillis。
  static const _morphInterval = Duration(milliseconds: 650);
  static const _globalRotationPeriod = Duration(milliseconds: 4666);

  late final AnimationController _cycleController;
  late final AnimationController _rotationController;

  // 对应 Compose 的 remember { Path() }:每实例复用,避免每帧分配。
  final Path _path = Path();

  int _morphIndex = 0;
  // Compose: morphRotationTargetAngle 初始 QuarterRotation(90°),每次 +90°。
  double _morphRotationTargetAngle = 90;

  /// M3E 开关缓存;关闭时回退经典转圈并停掉本组件的两个 ticker。
  bool _m3eEnabled = true;

  @override
  void initState() {
    super.initState();
    _cycleController =
        AnimationController(vsync: this, duration: _morphInterval)
          ..addStatusListener(_onCycleCompleted);
    _rotationController =
        AnimationController(vsync: this, duration: _globalRotationPeriod);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = M3eFlags.of(context).enabled;
    if (enabled == _m3eEnabled && _cycleController.isAnimating) return;
    _m3eEnabled = enabled;
    if (enabled) {
      if (!_cycleController.isAnimating) _cycleController.forward(from: 0);
      if (!_rotationController.isAnimating) _rotationController.repeat();
    } else {
      _cycleController.stop();
      _rotationController.stop();
    }
  }

  void _onCycleCompleted(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // 对应 Compose morph 动画 Finished 后:index 步进、progress 归零、目标角 +90°。
    // progress 1→0 的同时目标角 +90°,总旋转角保持连续。
    _morphIndex = (_morphIndex + 1) % _Md3LoadingGeometry.morphs.length;
    _morphRotationTargetAngle = (_morphRotationTargetAngle + 90) % 360;
    _cycleController.forward(from: 0);
  }

  @override
  void dispose() {
    _cycleController.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // M3E 关闭时回退经典转圈:size 语义平移,线宽按 48→4 的比例缩放。
    if (!M3eFlags.of(context).enabled) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: CircularProgressIndicator(
          color: widget.color,
          strokeWidth: (widget.size / 12).clamp(2.0, 4.0),
          padding: EdgeInsets.zero,
        ),
      );
    }

    // LoadingIndicatorTokens.ActiveIndicatorColor = Primary。
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_cycleController, _rotationController]),
          builder: (context, child) {
            final progress =
                _Md3LoadingGeometry.morphCurve.transform(_cycleController.value);
            return CustomPaint(
              painter: _LoadingIndicatorPainter(
                morphIndex: _morphIndex,
                morphProgress: progress,
                // Compose: rotate(progress * 90 + morphRotationTargetAngle +
                // globalRotation),弹簧过冲会带动旋转一起回弹。
                rotationDegrees: progress * 90 +
                    _morphRotationTargetAngle +
                    _rotationController.value * 360,
                color: color,
                path: _path,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 全局缓存的形状序列、morph 曲线与缩放因子:Morph 构造(曲线特征匹配)
/// 有成本,所有 LoadingSpinner 实例共享一份。
abstract final class _Md3LoadingGeometry {
  /// 把 650ms 周期映射为 morph 进度:前段是 LoadingIndicator.kt 专用弹簧
  /// spring(dampingRatio 0.6, stiffness 200, visibilityThreshold 0.1) 的
  /// 欠阻尼解析解(带过冲,峰值 ≈1.095),到达 Compose 的时长估算点
  /// (≈298ms)后 snap 到 1 并保持,等待周期剩余时间。
  static final M3eSpringCurve morphCurve =
      const M3eSpring(dampingRatio: 0.6, stiffness: 200).curveFor(
    _LoadingSpinnerState._morphInterval,
    visibilityThreshold: 0.1,
  );

  // LoadingIndicatorDefaults.IndeterminateIndicatorPolygons 的形状顺序。
  static final List<RoundedPolygon> _polygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  /// 循环 morph 序列(含尾→首闭环),对应 morphSequence(circularSequence=true)。
  static final List<Morph> morphs = [
    for (var i = 0; i < _polygons.length; i++)
      Morph(
        _polygons[i].normalized(),
        _polygons[(i + 1) % _polygons.length].normalized(),
      ),
  ];

  /// 让形状尽量撑满 size、且保证动画全程不越界的缩放因子。
  ///
  /// M3E 规格是"静态 maxBounds 缩放 × 38/48 容器留白",留白顺带兜住了
  /// morph 中间态与弹簧过冲的外扩;项目调用方把 [LoadingSpinner.size]
  /// 当作可见尺寸,不保留 38/48 留白,因此这里改为直接对动画全程
  /// (每段 morph × progress ∈ [0, 过冲峰值])采样,按 painter 的实际口径
  /// (控制点包围盒中心对齐 + 绕中心旋转)求最大回转半径,反推出
  /// 任意帧都不会画出 size 之外的最大缩放。
  static final double scaleFactor = 0.5 / _maxAnimatedRadius();

  static double _maxAnimatedRadius() {
    var worst = 0.0;
    const samples = 48;
    for (final morph in morphs) {
      for (var s = 0; s <= samples; s++) {
        final cubics = morph.asCubics(morphCurve.peakValue * s / samples);
        // 与 Path.getBounds 口径一致:包围盒含控制点;painter 每帧按该
        // 包围盒中心对齐画布中心后旋转,约束量即各点到该中心的最大距离。
        var minX = double.infinity, minY = double.infinity;
        var maxX = -double.infinity, maxY = -double.infinity;
        for (final c in cubics) {
          minX = math.min(minX, math.min(c.anchor0X, c.control0X));
          minX = math.min(minX, math.min(c.control1X, c.anchor1X));
          maxX = math.max(maxX, math.max(c.anchor0X, c.control0X));
          maxX = math.max(maxX, math.max(c.control1X, c.anchor1X));
          minY = math.min(minY, math.min(c.anchor0Y, c.control0Y));
          minY = math.min(minY, math.min(c.control1Y, c.anchor1Y));
          maxY = math.max(maxY, math.max(c.anchor0Y, c.control0Y));
          maxY = math.max(maxY, math.max(c.control1Y, c.anchor1Y));
        }
        final cx = (minX + maxX) / 2;
        final cy = (minY + maxY) / 2;
        for (final c in cubics) {
          for (final (x, y) in [
            (c.anchor0X, c.anchor0Y),
            (c.control0X, c.control0Y),
            (c.control1X, c.control1Y),
            (c.anchor1X, c.anchor1Y),
          ]) {
            final dx = x - cx;
            final dy = y - cy;
            worst = math.max(worst, math.sqrt(dx * dx + dy * dy));
          }
        }
      }
    }
    return worst;
  }
}

class _LoadingIndicatorPainter extends CustomPainter {
  _LoadingIndicatorPainter({
    required this.morphIndex,
    required this.morphProgress,
    required this.rotationDegrees,
    required this.color,
    required this.path,
  });

  final int morphIndex;
  final double morphProgress;
  final double rotationDegrees;
  final Color color;

  /// State 持有的复用 Path,toPath 内部每次会 reset。
  final Path path;

  static final Paint _paint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    _Md3LoadingGeometry.morphs[morphIndex]
        .toPath(progress: morphProgress, path: path);

    // 对应 Compose processPath:normalized 形状(0..1 空间)按
    // size × scaleFactor 缩放,包围盒中心对齐画布中心,再绕画布中心旋转。
    final scale = size.shortestSide * _Md3LoadingGeometry.scaleFactor;
    final boundsCenter = path.getBounds().center;
    final center = size.center(Offset.zero);
    _paint.color = color;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotationDegrees * math.pi / 180);
    canvas.translate(-boundsCenter.dx * scale, -boundsCenter.dy * scale);
    canvas.scale(scale);
    canvas.drawPath(path, _paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadingIndicatorPainter oldDelegate) {
    return oldDelegate.morphIndex != morphIndex ||
        oldDelegate.morphProgress != morphProgress ||
        oldDelegate.rotationDegrees != rotationDegrees ||
        oldDelegate.color != color;
  }
}
