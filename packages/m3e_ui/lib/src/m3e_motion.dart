import 'dart:math' as math;

import 'package:flutter/animation.dart';

/// 一档弹簧规格(阻尼比 + 刚度,质量恒为 1)。
///
/// 同一数对可派生两种消费形态:
/// - [description]:交给 SpringSimulation 做物理驱动(可继承手势/上游初速);
/// - [curveFor]:欠阻尼/临界阻尼解析解 [Curve],交给定周期的
///   AnimationController(零初速、目标值 1 的罐头动画)。
class M3eSpring {
  /// 阻尼比 ζ。仅支持 (0, 1]:<1 欠阻尼(带过冲),=1 临界阻尼。
  final double dampingRatio;

  /// 刚度(mass=1 时 ω₀ = √stiffness)。
  final double stiffness;

  const M3eSpring({required this.dampingRatio, required this.stiffness})
      : assert(dampingRatio > 0 && dampingRatio <= 1),
        assert(stiffness > 0);

  /// 物理驱动形态,供 SpringSimulation 使用。
  SpringDescription get description => SpringDescription.withDampingRatio(
        mass: 1.0,
        stiffness: stiffness,
        ratio: dampingRatio,
      );

  /// 解析解曲线形态,见 [M3eSpringCurve]。
  M3eSpringCurve curveFor(
    Duration period, {
    double visibilityThreshold = 0.001,
  }) =>
      M3eSpringCurve(
        spring: this,
        period: period,
        visibilityThreshold: visibilityThreshold,
      );
}

/// M3E motion scheme(expressive)的六档标准弹簧 token。
///
/// 数值 1:1 对照 Compose material3 的 tokens/ExpressiveMotionTokens.kt:
/// - spatial 三档欠阻尼(带过冲),用于位置/尺寸/形状等空间属性;
/// - effects 三档临界阻尼(不过冲),用于颜色/透明度等不可过冲的属性。
///
/// 注意:个别组件有自己的专用规格(如 LoadingIndicator.kt 的
/// spring(0.6, 200)),不属于六档,按各组件源码为准。
abstract final class M3eMotion {
  static const defaultSpatial = M3eSpring(dampingRatio: 0.8, stiffness: 380);
  static const fastSpatial = M3eSpring(dampingRatio: 0.6, stiffness: 800);
  static const slowSpatial = M3eSpring(dampingRatio: 0.8, stiffness: 200);

  static const defaultEffects = M3eSpring(dampingRatio: 1.0, stiffness: 1600);
  static const fastEffects = M3eSpring(dampingRatio: 1.0, stiffness: 3800);
  static const slowEffects = M3eSpring(dampingRatio: 1.0, stiffness: 800);
}

/// 把弹簧(初值 0、零初速、目标 1)的解析解映射为 [Curve]。
///
/// [period] 是曲线 t∈[0,1] 对应的真实时长;弹簧到达收敛时刻
/// (对照 Compose SpringEstimation:响应包络衰减到 [visibilityThreshold])
/// 后 snap 到 1 并保持,与 Compose 动画"结束值即目标值"的行为一致。
class M3eSpringCurve extends Curve {
  M3eSpringCurve({
    required this.spring,
    required this.period,
    this.visibilityThreshold = 0.001,
  }) {
    _omega0 = math.sqrt(spring.stiffness);
    _critical = spring.dampingRatio >= 1 - 1e-9;
    if (_critical) {
      // 临界阻尼 x(t) = 1 − (1 + ω₀t)·e^(−ω₀t)(x(0)=0、v(0)=0)。
      // 包络 (1 + ω₀t)·e^(−ω₀t) 单调衰减,二分求衰减到阈值的时刻。
      _omegaD = 0;
      _c2 = 0;
      peakValue = 1;
      var hi = 1.0;
      double envelope(double t) => (1 + _omega0 * t) * math.exp(-_omega0 * t);
      while (envelope(hi) > visibilityThreshold) {
        hi *= 2;
      }
      var lo = 0.0;
      for (var i = 0; i < 60; i++) {
        final mid = (lo + hi) / 2;
        if (envelope(mid) > visibilityThreshold) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      _settleSeconds = hi;
    } else {
      // 欠阻尼 x(t) = 1 + e^(−ζω₀t)·(c₁cos(ω_d t) + c₂sin(ω_d t)),
      // 初值 x(0)=0、v(0)=0 ⇒ c₁ = −1,c₂ = −ζ/√(1−ζ²)。
      final zeta = spring.dampingRatio;
      _omegaD = _omega0 * math.sqrt(1 - zeta * zeta);
      _c2 = _c1 * zeta / math.sqrt(1 - zeta * zeta);
      // Compose SpringEstimation.estimateUnderDamped:动画时长取包络
      // √(c₁²+c₂²)·e^(−ζω₀t) 衰减到 visibilityThreshold 的时刻。
      _settleSeconds =
          math.log(math.sqrt(_c1 * _c1 + _c2 * _c2) / visibilityThreshold) /
              (zeta * _omega0);
      // 首个过冲峰(发生在时长截断之前):1 + e^(−ζπ/√(1−ζ²))。
      peakValue = 1 + math.exp(-zeta * math.pi / math.sqrt(1 - zeta * zeta));
    }
  }

  final M3eSpring spring;
  final Duration period;
  final double visibilityThreshold;

  /// 曲线输出的最大值:欠阻尼为首个过冲峰(>1),临界阻尼为 1。
  /// 供调用方计算"动画全程不越界"之类的静态包络。
  late final double peakValue;

  static const double _c1 = -1;
  late final double _omega0;
  late final double _omegaD;
  late final double _c2;
  late final bool _critical;
  late final double _settleSeconds;

  @override
  double transformInternal(double t) {
    final seconds = t * period.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds >= _settleSeconds) return 1;
    if (_critical) {
      return 1 - (1 + _omega0 * seconds) * math.exp(-_omega0 * seconds);
    }
    final decay = math.exp(-spring.dampingRatio * _omega0 * seconds);
    final phase = _omegaD * seconds;
    return 1 + decay * (_c1 * math.cos(phase) + _c2 * math.sin(phase));
  }
}
