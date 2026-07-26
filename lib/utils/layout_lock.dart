/// 全屏/特殊状态下冻结动态布局切换
class LayoutLock {
  LayoutLock._();

  static int _lockCount = 0;

  /// 锁定期的判定快照**按阈值分桶**:各页 masterWidth+minDetailWidth
  /// 不同(默认 780、设置 860、追觅 920),之前是单个全局布尔 ——
  /// 锁定中(全屏视频/iframe)折叠时,不同页面会拿到彼此的判定结果
  /// (张冠李戴)。桶数有界于阈值组合数(个位数),不清理也无碍。
  static final Map<double, bool> _lastByThreshold = {};

  static bool get locked => _lockCount > 0;

  static void acquire() {
    _lockCount += 1;
  }

  static void release() {
    if (_lockCount > 0) {
      _lockCount -= 1;
    }
  }

  /// 在锁定期间返回上一次的布局判定结果，避免布局结构切换。
  /// [threshold] = masterWidth + minDetailWidth(调用方的双栏阈值)。
  static bool resolveCanShowBoth({
    required bool computed,
    required double threshold,
  }) {
    if (locked) {
      final last = _lastByThreshold[threshold];
      if (last != null) return last;
    }
    _lastByThreshold[threshold] = computed;
    return computed;
  }
}
