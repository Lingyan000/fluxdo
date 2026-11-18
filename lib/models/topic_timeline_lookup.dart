/// 话题时间线日期查找表（`post_stream.timeline_lookup`）。
///
/// 服务端把整条（过滤后的）帖子流压缩成至多 300 个「stream 位置 → 距今
/// 天数」的稀疏样本，只在天数变化处记录。据此无需加载帖子就能给任意
/// 位置估出日期：取不大于该位置的最近样本。超大话题（mega topic）
/// 服务端不下发，此时 [isEmpty]。
class TopicTimelineLookup {
  const TopicTimelineLookup._(this._entries, this._baseTime);

  static const TopicTimelineLookup empty = TopicTimelineLookup._([], null);

  /// 解析 `[[位置, 距今天数], ...]`；[receivedAt] 是拿到响应的本地时刻，
  /// 「距今天数」以它为基准换算成日期
  factory TopicTimelineLookup.fromJson(Object? json, DateTime receivedAt) {
    if (json is! List) return empty;
    final entries = <(int, int)>[];
    for (final item in json) {
      if (item is List &&
          item.length >= 2 &&
          item[0] is int &&
          item[1] is int) {
        entries.add((item[0] as int, item[1] as int));
      }
    }
    if (entries.isEmpty) return empty;
    return TopicTimelineLookup._(entries, receivedAt);
  }

  final List<(int, int)> _entries;
  final DateTime? _baseTime;

  bool get isEmpty => _entries.isEmpty;

  /// 位置（1 起）对应的距今天数；无数据时为 null
  int? daysAgoAt(int streamIndex) {
    if (_entries.isEmpty) return null;
    var low = 0;
    var high = _entries.length - 1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final position = _entries[mid].$1;
      if (position > streamIndex) {
        high = mid - 1;
      } else if (position < streamIndex) {
        low = mid + 1;
      } else {
        return _entries[mid].$2;
      }
    }
    // 落在两个样本之间：取前一个样本（位置更小的那个）
    final entry = high >= 0 ? _entries[high] : _entries[low];
    return entry.$2;
  }

  /// 位置对应的本地日期（只精确到天）；无数据时为 null
  DateTime? dateAt(int streamIndex) {
    final days = daysAgoAt(streamIndex);
    final base = _baseTime;
    if (days == null || base == null) return null;
    return DateTime(base.year, base.month, base.day - days);
  }
}
