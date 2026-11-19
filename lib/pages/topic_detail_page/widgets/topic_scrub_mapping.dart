import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;

enum TopicScrubScale { whole, nearby, single }

/// 从当前握柄位置按位移选楼。短拖一比一跟手，长扫后半程才补足到端点的行程。
double relativeScrubPosition({
  required double startPosition,
  required double pointerStart,
  required double pointer,
  required double extent,
}) {
  final delta = pointer - pointerStart;
  final room = delta > 0 ? extent - pointerStart : pointerStart;
  final travel = delta > 0 ? extent - startPosition : startPosition;
  // 起手就在端点附近时，轻轻向外拖也应基于当前楼层微调。
  if (room < 2 * kTouchSlop || travel <= room) {
    return (startPosition + delta).clamp(0.0, extent);
  }
  final tail = (2 * delta.abs() / room - 1).clamp(0.0, 1.0);
  final extra = (travel - room) * tail * tail * (3 - 2 * tail);
  return (startPosition + delta + delta.sign * extra).clamp(0.0, extent);
}

/// 底栏的横向位移选楼，上移距离选精度。坐标以可用轨道的左端为原点。
class TopicScrubTracker {
  TopicScrubTracker({
    required int startIndex,
    required int totalCount,
    required double surfaceWidth,
    required double startX,
  }) : totalCount = math.max(1, totalCount),
       surfaceWidth = math.max(1, surfaceWidth),
       _pointerX = startX {
    _position = startIndex.clamp(1, this.totalCount).toDouble();
    final fraction = this.totalCount > 1
        ? (_position - 1) / (this.totalCount - 1)
        : 1.0;
    _thumbX = fraction * this.surfaceWidth;
    _anchor();
  }

  static const double _stepWidth = 14;
  static const double _bandHeight = 38;
  static const double _bandMargin = 5;
  static bool canZoom(int totalCount, double width) =>
      (totalCount - 1) * _stepWidth > width;

  final int totalCount;
  final double surfaceWidth;
  double get _wholeRate => (totalCount - 1) / surfaceWidth;
  late final scales = [
    TopicScrubScale.whole,
    if (_wholeRate * _stepWidth > 8) TopicScrubScale.nearby,
    if (canZoom(totalCount, surfaceWidth)) TopicScrubScale.single,
  ];

  int _level = 0;
  double _pointerX;
  late double _thumbX;
  late double _anchorPointerX;
  double _lift = 0;
  late double _position;
  late double _anchorX;
  late double _anchorFloor;
  bool _turning = false;

  int get index => _position.round().clamp(1, totalCount);
  TopicScrubScale get scale => scales[_level];
  double get thumbX => _thumbX;

  double get floorsPerPixel => switch (scale) {
    TopicScrubScale.whole => _wholeRate,
    TopicScrubScale.nearby => math.sqrt(_wholeRate / _stepWidth),
    TopicScrubScale.single => 1 / _stepWidth,
  };

  /// 局部刻度在轨道左端对应的楼层，可位于首末楼之外。
  double get rulerOrigin => _position - thumbX * floorsPerPixel;

  void _anchor() {
    _anchorPointerX = _pointerX;
    _anchorX = thumbX;
    _anchorFloor = _position;
  }

  double _overviewAt(double x) {
    if (x <= 0) return 1;
    if (x >= surfaceWidth) return totalCount.toDouble();
    // 从局部刻度放回底栏时保留当前楼号，两侧行程分别走到首末楼。
    if (x < _anchorX) return 1 + (_anchorFloor - 1) * x / _anchorX;
    if (x > _anchorX) {
      return _anchorFloor +
          (totalCount - _anchorFloor) *
              (x - _anchorX) /
              (surfaceWidth - _anchorX);
    }
    return _anchorFloor;
  }

  void update(double x, double lift) {
    final dx = x - _pointerX;
    final dy = lift - _lift;
    _pointerX = x;
    _lift = lift;
    var next = _level;
    while (next + 1 < scales.length &&
        lift >= (next + 0.5) * _bandHeight + _bandMargin) {
      next++;
    }
    while (next > 0 && lift <= (next - 0.5) * _bandHeight - _bandMargin) {
      next--;
    }
    // 斜着抬高拇指时吸收横向偏移，防止换档途中跳过几十楼。
    if (next != _level || (dy != 0 && dy.abs() >= dx.abs())) {
      if (next != _level) _position = index.toDouble();
      _level = next;
      _anchor();
      _turning = true;
      return;
    }
    final delta = x - _anchorPointerX;
    if (dx == 0 || (_turning && delta.abs() < 2)) return;
    _turning = false;
    if (scale == TopicScrubScale.whole) {
      _thumbX = relativeScrubPosition(
        startPosition: _anchorX,
        pointerStart: _anchorPointerX,
        pointer: x,
        extent: surfaceWidth,
      );
      _position = _overviewAt(thumbX);
    } else {
      _position = (_anchorFloor + delta * floorsPerPixel).clamp(
        1.0,
        totalCount.toDouble(),
      );
      _thumbX = (_anchorX + (_position - _anchorFloor) / floorsPerPixel).clamp(
        0.0,
        surfaceWidth,
      );
    }
    if ((_position == 1 && dx < 0) || (_position == totalCount && dx > 0)) {
      _anchor();
    }
  }
}
