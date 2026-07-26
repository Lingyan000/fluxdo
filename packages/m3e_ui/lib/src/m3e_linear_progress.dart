import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'm3e_flags.dart';

/// Material 3 Expressive wavy 线性进度条(确定态 + 不定态)。
///
/// 规格逐项对照 Compose material3 的 WavyProgressIndicator.kt 与
/// tokens/LinearProgressIndicatorTokens.kt:
/// - active/track stroke 均 4dp、round cap;容器高 10dp(振幅 3dp×2 + 4dp);
/// - active 段与 track 段之间留 4dp gap,track 尾端画 4dp stop indicator;
/// - 确定态:波长 40dp、波速 40dp/s;progress ≤0.1 或 ≥0.95 时振幅归 0
///   (直线),振幅过渡 500ms(增幅 EasingStandard、减幅 EmphasizedAccelerate);
/// - 不定态:波长 20dp、振幅恒满;双线 1750ms keyframes
///   (head 0→1000 / tail 250→1250 / head₂ 650→1500 / tail₂ 900→1750,
///   均 EmphasizedAccelerate),与 Flutter 老 painter 的 1800ms 曲线不同。
///
/// [value] 为 null 时是不定态。M3E 开关关闭时回退 [LinearProgressIndicator]。
class M3eLinearProgress extends StatefulWidget {
  final double? value;
  final Color? color;
  final Color? trackColor;
  final double minHeight;

  const M3eLinearProgress({
    super.key,
    this.value,
    this.color,
    this.trackColor,
    this.minHeight = _kContainerHeight,
  });

  @override
  State<M3eLinearProgress> createState() => _M3eLinearProgressState();
}

// ---- Compose token 常量(dp)----
const double _kStrokeWidth = 4;
const double _kAmplitude = 3;
const double _kContainerHeight = 10; // 3×2 + 4
const double _kTrackGap = 4;
const double _kStopSize = 4;
const double _kWavelengthDeterminate = 40;
const double _kWavelengthIndeterminate = 20;

/// 波速 = 1 波长/秒(两态同规则)。
const double _kWaveSpeedDeterminate = _kWavelengthDeterminate;
const double _kWaveSpeedIndeterminate = _kWavelengthIndeterminate;

/// 不定态双线周期与 keyframes(EmphasizedAccelerate)。
const int _kIndeterminateDurationMs = 1750;
const Curve _kEmphasizedAccelerate = Cubic(0.3, 0, 0.8, 0.15);
const Curve _kEasingStandard = Cubic(0.2, 0, 0, 1);

/// 确定态振幅开合的进度区间与过渡时长。
const double _kAmplitudeOnMin = 0.1;
const double _kAmplitudeOnMax = 0.95;
const Duration _kAmplitudeAnimDuration = Duration(milliseconds: 500);

class _M3eLinearProgressState extends State<M3eLinearProgress>
    with TickerProviderStateMixin {
  /// 相位滚动 + 不定态双线共用的主控制器(1750ms 循环)。
  late final AnimationController _controller;

  /// 确定态振幅 0↔1 的过渡。
  late final AnimationController _amplitudeController;

  /// 累计相位基准:_controller 每圈回绕时把整圈相位沉淀进来,
  /// 保证波形滚动跨圈连续。
  double _phaseBase = 0;
  int _lastCycle = 0;

  bool get _indeterminate => widget.value == null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _kIndeterminateDurationMs),
    )..addListener(_trackCycle);
    _amplitudeController = AnimationController(
      vsync: this,
      duration: _kAmplitudeAnimDuration,
      value: _amplitudeTargetFor(widget.value),
    );
  }

  void _trackCycle() {
    // repeat() 回绕检测:value 突然变小说明进入下一圈。
    final cycleValue = _controller.value;
    if (cycleValue < 0.5 && _lastCycle == 1) {
      _phaseBase += 1;
    }
    _lastCycle = cycleValue < 0.5 ? 0 : 1;
  }

  double _amplitudeTargetFor(double? value) {
    if (value == null) return 1;
    return (value > _kAmplitudeOnMin && value < _kAmplitudeOnMax) ? 1 : 0;
  }

  @override
  void didUpdateWidget(M3eLinearProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _amplitudeTargetFor(widget.value);
    if (target != _amplitudeController.value ||
        _amplitudeController.isAnimating) {
      // 增幅 EasingStandard / 减幅 EmphasizedAccelerate,各 500ms。
      _amplitudeController.animateTo(
        target,
        curve: target > _amplitudeController.value
            ? _kEasingStandard
            : _kEmphasizedAccelerate,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _amplitudeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return LinearProgressIndicator(
        value: widget.value,
        color: widget.color,
        backgroundColor: widget.trackColor,
        minHeight: math.min(widget.minHeight, _kStrokeWidth),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final trackColor = widget.trackColor ?? scheme.secondaryContainer;

    // 动画驱动:不定态一直转;确定态只在振幅>0(波形滚动)时转。
    final needsTicker = _indeterminate || _amplitudeController.value > 0;
    if (needsTicker && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!needsTicker && _controller.isAnimating) {
      _controller.stop();
    }

    return Semantics(
      value: widget.value == null
          ? null
          : '${(widget.value!.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        height: math.max(widget.minHeight, _kContainerHeight),
        width: double.infinity,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_controller, _amplitudeController]),
            builder: (context, _) {
              return CustomPaint(
                painter: _WavyProgressPainter(
                  value: widget.value?.clamp(0.0, 1.0),
                  t: _controller.value,
                  phase: _phaseBase + _controller.value,
                  amplitudeFraction: _amplitudeController.value,
                  color: color,
                  trackColor: trackColor,
                  textDirection: Directionality.of(context),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 不定态双线的四个 keyframe 曲线(区间归一化到 0..1 周期)。
class _Keyframe {
  final double begin;
  final double end;
  const _Keyframe(this.begin, this.end);

  double transform(double t) {
    if (t <= begin) return 0;
    if (t >= end) return 1;
    return _kEmphasizedAccelerate.transform((t - begin) / (end - begin));
  }
}

const _kLine1Head = _Keyframe(0 / 1750, 1000 / 1750);
const _kLine1Tail = _Keyframe(250 / 1750, 1250 / 1750);
const _kLine2Head = _Keyframe(650 / 1750, 1500 / 1750);
const _kLine2Tail = _Keyframe(900 / 1750, 1750 / 1750);

class _WavyProgressPainter extends CustomPainter {
  _WavyProgressPainter({
    required this.value,
    required this.t,
    required this.phase,
    required this.amplitudeFraction,
    required this.color,
    required this.trackColor,
    required this.textDirection,
  });

  /// null = 不定态。
  final double? value;

  /// 不定态周期进度 0..1。
  final double t;

  /// 累计相位(圈数 + 圈内进度),驱动波形滚动。
  final double phase;

  /// 振幅比例 0..1(确定态开合动画;不定态恒 1)。
  final double amplitudeFraction;

  final Color color;
  final Color trackColor;
  final TextDirection textDirection;

  static final Paint _activePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = _kStrokeWidth
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
  static final Paint _trackPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = _kStrokeWidth
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
  static final Paint _stopPaint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    if (textDirection == TextDirection.rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    // round cap 会在线段两端各外扩半个线宽,预留避免裁切。
    final inset = _kStrokeWidth / 2;
    final width = size.width - inset * 2;
    if (width <= 0) return;
    final centerY = size.height / 2;
    canvas.translate(inset, 0);

    _activePaint.color = color;
    _trackPaint.color = trackColor;
    _stopPaint.color = color;

    if (value != null) {
      _paintDeterminate(canvas, width, centerY);
    } else {
      _paintIndeterminate(canvas, width, centerY);
    }
  }

  void _paintDeterminate(Canvas canvas, double width, double centerY) {
    final v = value!;
    final activeEnd = width * v;

    // active 波形段:x ∈ [0, activeEnd]。
    if (activeEnd > 0) {
      _drawWavySegment(
        canvas,
        start: 0,
        end: activeEnd,
        centerY: centerY,
        wavelength: _kWavelengthDeterminate,
        speed: _kWaveSpeedDeterminate,
        amplitude: _kAmplitude * amplitudeFraction,
      );
    }

    // track 段:active 尾 + gap 起画;gap 在极小进度时线性压缩
    // (对照 SDK _kTrackGapRampDownThreshold 的防空洞处理)。
    final gap = activeEnd <= 0
        ? 0.0
        : _kTrackGap * math.min(1.0, v / 0.01).clamp(0.0, 1.0);
    final trackStart = math.min(activeEnd + gap, width);
    if (trackStart < width) {
      canvas.drawLine(
        Offset(trackStart, centerY),
        Offset(width, centerY),
        _trackPaint,
      );
    }

    // stop indicator:track 尾端 4dp 圆点(进度未满时)。
    if (v < 1) {
      canvas.drawCircle(
        Offset(width, centerY),
        _kStopSize / 2,
        _stopPaint,
      );
    }
  }

  void _paintIndeterminate(Canvas canvas, double width, double centerY) {
    // 双线各自 [tail, head] 区间画 active 波形,其余画 track。
    final segments = <(double, double)>[
      (_kLine1Tail.transform(t) * width, _kLine1Head.transform(t) * width),
      (_kLine2Tail.transform(t) * width, _kLine2Head.transform(t) * width),
    ]..removeWhere((s) => s.$2 - s.$1 < 0.01);
    segments.sort((a, b) => a.$1.compareTo(b.$1));

    // track:相邻 active 段之间(含首尾)的空隙,两侧各让 4dp gap。
    var cursor = 0.0;
    for (final (segStart, segEnd) in segments) {
      final gapEnd = segStart - _kTrackGap;
      if (gapEnd > cursor) {
        canvas.drawLine(
          Offset(cursor, centerY),
          Offset(gapEnd, centerY),
          _trackPaint,
        );
      }
      cursor = segEnd + _kTrackGap;
    }
    if (cursor < width) {
      canvas.drawLine(
        Offset(cursor, centerY),
        Offset(width, centerY),
        _trackPaint,
      );
    }

    for (final (segStart, segEnd) in segments) {
      _drawWavySegment(
        canvas,
        start: segStart,
        end: segEnd,
        centerY: centerY,
        wavelength: _kWavelengthIndeterminate,
        speed: _kWaveSpeedIndeterminate,
        amplitude: _kAmplitude * amplitudeFraction,
      );
    }
  }

  /// 画一段正弦波:相位 = 累计时间×速度/波长×2π,沿 -x 方向滚动。
  void _drawWavySegment(
    Canvas canvas, {
    required double start,
    required double end,
    required double centerY,
    required double wavelength,
    required double speed,
    required double amplitude,
  }) {
    if (amplitude <= 0.01) {
      canvas.drawLine(Offset(start, centerY), Offset(end, centerY), _activePaint);
      return;
    }
    // 时间相位:phase 单位是"周期数",一个周期 1.75s。
    final timePhase =
        phase * (_kIndeterminateDurationMs / 1000) * speed / wavelength;
    final path = Path();
    // 采样步长 2dp,正弦足够平滑且成本可控。
    const step = 2.0;
    var x = start;
    var first = true;
    while (true) {
      final clampedX = math.min(x, end);
      final y = centerY +
          amplitude *
              math.sin(2 * math.pi * (clampedX / wavelength - timePhase));
      if (first) {
        path.moveTo(clampedX, y);
        first = false;
      } else {
        path.lineTo(clampedX, y);
      }
      if (clampedX >= end) break;
      x += step;
    }
    canvas.drawPath(path, _activePaint);
  }

  @override
  bool shouldRepaint(covariant _WavyProgressPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.t != t ||
        oldDelegate.phase != phase ||
        oldDelegate.amplitudeFraction != amplitudeFraction ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.textDirection != textDirection;
  }
}
