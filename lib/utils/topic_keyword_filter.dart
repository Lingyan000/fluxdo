import '../models/topic.dart';

/// 标题关键词过滤工具。
///
/// 关键词在 [PreferencesNotifier] 保存时已 trim + 去重；调用方需传入
/// `normalizedFilterKeywords`（已 lowercase）以避免重复归一化开销。
class TopicKeywordFilter {
  TopicKeywordFilter._();

  /// 应用关键词过滤，返回 `(可见列表, 隐藏数量)`。
  ///
  /// - [normalizedKeywords] 必须是已 trim + lowercase + 去空的列表。
  /// - [wholeWord] 为 true 时：对纯 ASCII word-char 关键词（如 `ai`、`db_2`）
  ///   使用单词边界（`\b`）匹配；对含非 word-char（如中文）的关键词依然走子串
  ///   匹配——Dart 的 `\b` 不在两个非 word-char 之间产生边界，强制套 `\b`
  ///   会让 `\b中文\b` 几乎不可能命中。
  static (List<Topic> visible, int hiddenCount) apply(
    List<Topic> topics, {
    required List<String> normalizedKeywords,
    required bool wholeWord,
  }) {
    if (normalizedKeywords.isEmpty || topics.isEmpty) {
      return (topics, 0);
    }

    final substrings = <String>[];
    final regexes = <RegExp>[];
    for (final keyword in normalizedKeywords) {
      if (wholeWord && _isAsciiWordOnly(keyword)) {
        regexes.add(
          RegExp(r'\b' + RegExp.escape(keyword) + r'\b', caseSensitive: false),
        );
      } else {
        substrings.add(keyword);
      }
    }

    final visible = <Topic>[];
    var hidden = 0;
    for (final topic in topics) {
      if (_matches(topic.title, substrings, regexes)) {
        hidden++;
      } else {
        visible.add(topic);
      }
    }
    return (visible, hidden);
  }

  static bool _matches(
    String title,
    List<String> substrings,
    List<RegExp> regexes,
  ) {
    if (substrings.isNotEmpty) {
      final lower = title.toLowerCase();
      for (final keyword in substrings) {
        if (lower.contains(keyword)) return true;
      }
    }
    for (final re in regexes) {
      if (re.hasMatch(title)) return true;
    }
    return false;
  }

  /// 关键词是否全部由 ASCII 字母 / 数字 / 下划线组成（`\w` 等价集）。
  static bool _isAsciiWordOnly(String s) {
    if (s.isEmpty) return false;
    for (final code in s.codeUnits) {
      final isWord =
          (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5A) || // A-Z
          (code >= 0x61 && code <= 0x7A) || // a-z
          code == 0x5F; // _
      if (!isWord) return false;
    }
    return true;
  }

  /// loadMore 完成后判断是否需要自动再加载一次。
  ///
  /// 当关键词命中率高时，单次 loadMore 实际新增可见条目很少，会让用户感到
  /// "划到底什么也没出来"。本判定在以下都满足时返回 true：
  /// - 仍有更多页（[hasMore]）
  /// - 本次 loadMore 的可见增量小于 [threshold]
  /// - 自动续加载次数未超 [maxAttempts]
  static bool shouldAutoLoadMore({
    required int visibleBefore,
    required int visibleAfter,
    required bool hasMore,
    required int attempts,
    int threshold = 5,
    int maxAttempts = 3,
  }) {
    if (!hasMore) return false;
    if (attempts >= maxAttempts) return false;
    return (visibleAfter - visibleBefore) < threshold;
  }
}
