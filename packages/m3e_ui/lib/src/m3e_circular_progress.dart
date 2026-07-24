import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'm3e_flags.dart';

/// Material 3 Expressive wavy 圆形进度环(确定态 + 不定态)。
///
/// 规格对照 Compose WavyProgressIndicator.kt(circular)+
/// CircularProgressIndicatorTokens:
/// - active/track stroke 4dp round cap,active 弧与 track 弧间留 gap;
/// - **circular 专用波形 token**(与 linear 的 40dp/3dp 完全不同):
///   基准 48dp 容器 · 波长 15dp · 振幅 1.6dp —— 换算为几何相似量
///   即 8 个波/圈、振幅 = 8% 半径,是"深花边"观感而非浅波纹;
/// - 确定态:progress ≤0.1 或 ≥0.95 时 amplitude=0(平滑圆弧),
///   区间内满幅花边(振幅过渡 500ms);从 12 点钟方向顺时针,画 track;
/// - **不定态([value] 传 null)**:amplitude 恒满,弧长伸缩 + 旋转
///   走 Material 官方不定态状态机(head/tail 各 1333ms fastOutSlowIn、
///   2222ms/圈附加旋转),波浪弧绕环追逐,不画 track;
/// - 波形恒以 1 波长/秒绕环爬行。
///
/// M3E 开关关闭时回退 [CircularProgressIndicator]。
class M3eCircularProgress extends StatefulWidget {
  /// 进度 0..1;null = 不定态。
  final double? value;

  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? trackColor;

  const M3eCircularProgress({
    super.key,
    this.value,
    this.size = 48,
    this.strokeWidth = 4,
    this.color,
    this.trackColor,
  });

  @override
  State<M3eCircularProgress> createState() => _M3eCircularProgressState();
}

/// 振幅开合区间与过渡时长(同 linear 规格)。
const double _kAmplitudeOnMin = 0.1;
const double _kAmplitudeOnMax = 0.95;
const Duration _kAmplitudeAnimDuration = Duration(milliseconds: 500);
const Curve _kEasingStandard = Cubic(0.2, 0, 0, 1);
const Curve _kEmphasizedAccelerate = Cubic(0.3, 0, 0.8, 0.15);

/// Circular 专用波形 token(CircularProgressIndicatorTokens,与 linear
/// 的 40dp/3dp 不同!):基准 48dp 容器(半径 20)· 波长 15dp ·
/// 振幅 1.6dp。换算成几何相似量,任意尺寸保持真机观感:
/// - 波数 = 周长/波长 ≈ 8.4 → 取整 8(密集花边,不是缓波);
/// - 振幅 = 半径 × (1.6/20) = 8% 半径。
const int _kWaveCount = 8;
const double _kAmplitudeRatio = 1.6 / 20;

/// track gap(dp,弧两端各让开的角度按此弦长换算)。
const double _kTrackGap = 4;

/// 不定态状态机常量(Material 官方 _CircularProgressIndicatorState 同款):
/// 完整周期 = 1333×2222ms,内含 2222 个弧伸缩节拍(SawTooth)与
/// 1333 圈附加旋转,两者互质错峰形成"追逐"观感。
const int _kIndeterminateCycleMs = 1333 * 2222;
const int _kPathCount = _kIndeterminateCycleMs ~/ 1333;
const int _kRotationCount = _kIndeterminateCycleMs ~/ 2222;

class _M3eCircularProgressState extends State<M3eCircularProgress>
    with TickerProviderStateMixin {
  /// 波形滚动:规格 = 1 波长/秒。wavePhase 0→1 即波形平移一个波长。
  late final AnimationController _wave;
  late final AnimationController _amplitude;

  /// 不定态弧伸缩/旋转主控制器(仅 value == null 时运转)。
  late final AnimationController _spin;

  // Material 官方四曲线(head/tail 弧端、SawTooth 偏移与旋转)。
  static final Animatable<double> _strokeHeadTween = CurveTween(
    curve: const Interval(0.0, 0.5, curve: Curves.fastOutSlowIn),
  ).chain(CurveTween(curve: const SawTooth(_kPathCount)));
  static final Animatable<double> _strokeTailTween = CurveTween(
    curve: const Interval(0.5, 1.0, curve: Curves.fastOutSlowIn),
  ).chain(CurveTween(curve: const SawTooth(_kPathCount)));
  static final Animatable<double> _offsetTween =
      CurveTween(curve: const SawTooth(_kPathCount));
  static final Animatable<double> _rotationTween =
      CurveTween(curve: const SawTooth(_kRotationCount));

  bool get _indeterminate => widget.value == null;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _kIndeterminateCycleMs),
    );
    _amplitude = AnimationController(
      vsync: this,
      duration: _kAmplitudeAnimDuration,
      value: _targetAmplitude(widget.value),
    );
    _syncTickers();
  }

  double _targetAmplitude(double? v) {
    if (v == null) return 1; // 不定态恒满幅
    return (v > _kAmplitudeOnMin && v < _kAmplitudeOnMax) ? 1 : 0;
  }

  void _syncTickers() {
    final needsWave = _amplitude.value > 0 || _amplitude.isAnimating;
    if (needsWave && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!needsWave && _wave.isAnimating) {
      _wave.stop();
    }
    if (_indeterminate && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!_indeterminate && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void didUpdateWidget(M3eCircularProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _targetAmplitude(widget.value);
    if (target != _amplitude.value || _amplitude.isAnimating) {
      _amplitude
          .animateTo(
            target,
            curve: target > _amplitude.value
                ? _kEasingStandard
                : _kEmphasizedAccelerate,
          )
          .whenComplete(_syncTickers);
    }
    _syncTickers();
  }

  @override
  void dispose() {
    _wave.dispose();
    _amplitude.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: CircularProgressIndicator(
          value: widget.value?.clamp(0.0, 1.0),
          strokeWidth: widget.strokeWidth,
          color: widget.color,
          backgroundColor: widget.trackColor,
          padding: EdgeInsets.zero,
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final v = widget.value?.clamp(0.0, 1.0);
    return Semantics(
      value: v == null ? null : '${(v * 100).round()}%',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_wave, _amplitude, _spin]),
            builder: (context, _) {
              final double arcStart;
              final double arcSweep;
              final bool drawTrack;
              if (v == null) {
                // Material 官方不定态弧几何:tail 追 head,叠加 SawTooth
                // 偏移与整圈旋转。
                final head = _strokeHeadTween.evaluate(_spin);
                final tail = _strokeTailTween.evaluate(_spin);
                final offset = _offsetTween.evaluate(_spin);
                final rotation = _rotationTween.evaluate(_spin);
                arcStart = -math.pi / 2 +
                    tail * 3 / 2 * math.pi +
                    rotation * math.pi * 2 +
                    offset * 0.5 * math.pi;
                arcSweep = math.max(
                  head * 3 / 2 * math.pi - tail * 3 / 2 * math.pi,
                  0.001,
                );
                drawTrack = false;
              } else {
                arcStart = -math.pi / 2;
                arcSweep = 2 * math.pi * v;
                drawTrack = true;
              }
              return CustomPaint(
                painter: _WavyCircularPainter(
                  arcStart: arcStart,
                  arcSweep: arcSweep,
                  drawTrack: drawTrack,
                  fullValue: v ?? 0,
                  wavePhase: _wave.value,
                  amplitudeFraction: _amplitude.value,
                  strokeWidth: widget.strokeWidth,
                  color: widget.color ?? scheme.primary,
                  trackColor: widget.trackColor ?? scheme.secondaryContainer,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WavyCircularPainter extends CustomPainter {
  _WavyCircularPainter({
    required this.arcStart,
    required this.arcSweep,
    required this.drawTrack,
    required this.fullValue,
    required this.wavePhase,
    required this.amplitudeFraction,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
  });

  /// active 弧的起始角与扫过角(弧几何由 State 决定,确定/不定态同一
  /// painter)。
  final double arcStart;
  final double arcSweep;

  /// 是否画 track(确定态画,不定态不画,与 M3 新样式一致)。
  final bool drawTrack;

  /// 确定态进度(track gap 计算用;不定态传 0)。
  final double fullValue;

  final double wavePhase;
  final double amplitudeFraction;
  final double strokeWidth;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // 振幅按半径比例(token 1.6/20),真机同款的深花边;先解出基准半径:
    // outer = r + r*ratio + stroke/2 = size/2 → r = (size/2 - stroke/2)/(1+ratio)。
    final half = size.shortestSide / 2;
    final radius = (half - strokeWidth / 2) / (1 + _kAmplitudeRatio);
    if (radius <= 0) return;
    final amplitude = radius * _kAmplitudeRatio * amplitudeFraction;

    final activePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (drawTrack) {
      final trackPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = trackColor;
      // gap 弦长 → 圆心角;track 平滑圆,不带波浪。
      final gapAngle = (_kTrackGap + strokeWidth) / radius;
      final trackStart = arcStart + arcSweep + gapAngle;
      final trackSweep = 2 * math.pi - arcSweep - 2 * gapAngle;
      if (trackSweep > 0 && fullValue < 1) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          trackStart,
          trackSweep,
          false,
          trackPaint,
        );
      }
    }

    if (arcSweep <= 0.002) return;

    // active 波浪弧:半径按角度叠加正弦扰动逐点采样。
    // 波数固定 8(token 周长/波长 ≈8.4 取整,保证首尾相位连续);
    // wavePhase 0→1 = 波形平移一个波长(1 波长/秒规格)。
    // 波形相位锚定世界坐标(angle 本身),弧移动时波形独立爬行。
    final path = Path();
    // 采样步长 ~1.5dp 对应的角度(深波形需要更细的步长)。
    final step = 1.5 / radius;
    var first = true;
    for (var a = 0.0; a <= arcSweep + step / 2; a += step) {
      final angle = arcStart + math.min(a, arcSweep);
      final r = radius +
          (amplitude <= 0.01
              ? 0
              : amplitude *
                  math.sin(_kWaveCount * angle - wavePhase * 2 * math.pi));
      final p = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
      if (a >= arcSweep) break;
    }
    canvas.drawPath(path, activePaint);
  }

  @override
  bool shouldRepaint(covariant _WavyCircularPainter oldDelegate) {
    return oldDelegate.arcStart != arcStart ||
        oldDelegate.arcSweep != arcSweep ||
        oldDelegate.drawTrack != drawTrack ||
        oldDelegate.fullValue != fullValue ||
        oldDelegate.wavePhase != wavePhase ||
        oldDelegate.amplitudeFraction != amplitudeFraction ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
