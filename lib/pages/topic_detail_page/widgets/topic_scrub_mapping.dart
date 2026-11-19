import 'dart:math' as math;

enum TopicScrubScale { whole, nearby, single }

/// 底栏的横坐标选楼，上移距离选精度。坐标以可用轨道的左端为原点。
class TopicScrubTracker {
  TopicScrubTracker({
    required int startIndex,
    required int totalCount,
    required double surfaceWidth,
    required double startX,
    required bool fromHandle,
  }) : totalCount = math.max(1, totalCount),
       surfaceWidth = math.max(1, surfaceWidth),
       _x = startX {
    _position = fromHandle
        ? startIndex.clamp(1, this.totalCount).toDouble()
        : 1 + thumbX * _wholeRate;
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
  double _x;
  double _lift = 0;
  late double _position;
  late double _anchorX;
  late double _anchorFloor;
  bool _turning = false;

  int get index => _position.round().clamp(1, totalCount);
  TopicScrubScale get scale => scales[_level];
  double get thumbX => _x.clamp(0.0, surfaceWidth);

  double get floorsPerPixel => switch (scale) {
    TopicScrubScale.whole => _wholeRate,
    TopicScrubScale.nearby => math.sqrt(_wholeRate / _stepWidth),
    TopicScrubScale.single => 1 / _stepWidth,
  };

  /// 局部刻度在轨道左端对应的楼层，可位于首末楼之外。
  double get rulerOrigin => _anchorFloor - _anchorX * floorsPerPixel;

  void _anchor() {
    _anchorX = scale == TopicScrubScale.whole ? thumbX : _x;
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
    final dx = x - _x;
    final dy = lift - _lift;
    _x = x;
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
    if (dx == 0 || (_turning && (x - _anchorX).abs() < 2)) return;
    _turning = false;
    final value = scale == TopicScrubScale.whole
        ? _overviewAt(x)
        : _anchorFloor + (x - _anchorX) * floorsPerPixel;
    _position = value.clamp(1.0, totalCount.toDouble());
    if ((_position == 1 && dx < 0) || (_position == totalCount && dx > 0)) {
      _anchor();
    }
  }
}
