import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// 2D 惯性滑动模拟器:双轴 FrictionSimulation,采样时钳制到边界
/// (撞边即停 —— 显示位置在结构上不可能越界)。
/// 由 GestureAnimation 以线性时间轴采样 [positionAt] 驱动。
class Inertia2DSimulation {
  Inertia2DSimulation({
    required this.startPosition,
    required Offset velocity,
    required double friction,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  }) : _xSim = FrictionSimulation(friction, startPosition.dx, velocity.dx),
       _ySim = FrictionSimulation(friction, startPosition.dy, velocity.dy);

  final Offset startPosition;
  final FrictionSimulation _xSim;
  final FrictionSimulation _ySim;

  // 边界
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  /// 获取指定时间点的位置（带边界限制）
  Offset positionAt(double time) {
    final double x = _xSim.x(time).clamp(minX, maxX);
    final double y = _ySim.x(time).clamp(minY, maxY);
    return Offset(x, y);
  }
}
