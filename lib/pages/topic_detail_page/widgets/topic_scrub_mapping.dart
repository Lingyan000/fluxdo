/// 底栏拖动定位：手指横向移动 → 目标楼层（stream 索引，1 起）。
///
/// 速度自适应的增量映射（同鼠标指针加速）：
/// - 慢慢移动时每 [stepWidth] 走一楼，可以逐楼精确定位；
/// - 移动越快增益越大，平滑过渡到上限。上限由楼数推导——全宽快划一次
///   大约走完整个话题——长话题也不需要额外的精细模式，不写死倍率；
/// - 增量累积，中途反向慢慢挪就逐楼退回。
///
/// 向右为往后读（与进度线填充方向一致）。
class TopicScrubTracker {
  TopicScrubTracker({
    required int startIndex,
    required this.totalCount,
    required this.surfaceWidth,
    this.stepWidth = 24,
  }) : _position = startIndex
           .clamp(1, totalCount < 1 ? 1 : totalCount)
           .toDouble();

  final int totalCount;

  /// 可拖动的手势面宽度（扣除屏幕边缘手势区）
  final double surfaceWidth;

  /// 慢速时每走一楼需要的位移
  final double stepWidth;

  /// 低于此速度（px/s）为精细定位，增益 1
  static const double slowSpeed = 160;

  /// 高于此速度（px/s）增益达到上限
  static const double fastSpeed = 1400;

  double _position;
  double _speed = 0;

  /// 当前目标楼层
  int get index => _position.round().clamp(1, totalCount < 1 ? 1 : totalCount);

  /// 增益上限：全宽快划一次约覆盖整个话题，楼数少时就是 1
  double get maxGain {
    if (surfaceWidth <= 0) return 1;
    final gain = totalCount * stepWidth / surfaceWidth;
    return gain < 1 ? 1 : gain;
  }

  /// 按当前速度插值的增益（smoothstep，起止都平滑）
  double gainFor(double speed) {
    final t = ((speed - slowSpeed) / (fastSpeed - slowSpeed)).clamp(0.0, 1.0);
    final eased = t * t * (3 - 2 * t);
    return 1 + (maxGain - 1) * eased;
  }

  /// 喂入一次移动：[dx] 横向位移，[dtSeconds] 距上次的时间。返回目标楼层
  int update(double dx, double dtSeconds) {
    if (totalCount <= 1) return 1;
    if (dtSeconds > 0) {
      final instant = dx.abs() / dtSeconds;
      // 指数平滑，过滤单次事件的抖动；间隔越长新样本权重越大
      final alpha = (dtSeconds / 0.05).clamp(0.2, 1.0);
      _speed += (instant - _speed) * alpha;
    }
    _position = (_position + dx / stepWidth * gainFor(_speed)).clamp(
      1.0,
      totalCount.toDouble(),
    );
    return index;
  }
}
