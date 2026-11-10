import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lunar/lunar.dart';

/// 节日定义（`assets/festivals/festivals.json`）。
@immutable
class FestivalDef {
  const FestivalDef({
    required this.id,
    required this.themeId,
    required this.emoji,
    required this.emojiChar,
    required this.name,
    required this.greeting,
    required this.rule,
    required this.windowStart,
    required this.windowEnd,
    required this.priority,
  });

  final String id;

  /// 节日配色主题 id（`group: festival`，不进画廊）。
  final String themeId;

  /// 表情短码（应用内 Noto 表情）与对应字符（纯文本场景）。
  final String emoji;
  final String emojiChar;

  final Map<String, String> name;
  final Map<String, String> greeting;
  final FestivalRule rule;

  /// 生效窗口：相对节日当天的偏移天数（含两端）。
  final int windowStart;
  final int windowEnd;

  /// 窗口重叠时优先级高者生效。
  final int priority;

  factory FestivalDef.fromJson(Map<String, dynamic> json) {
    final window = (json['window'] as List).cast<int>();
    Map<String, String> names(Object? v) => {
      for (final e in (v as Map).entries) e.key as String: e.value as String,
    };
    return FestivalDef(
      id: json['id'] as String,
      themeId: json['themeId'] as String,
      emoji: json['emoji'] as String,
      emojiChar: json['emojiChar'] as String,
      name: names(json['name']),
      greeting: names(json['greeting']),
      rule: FestivalRule.fromJson(json['rule'] as Map<String, dynamic>),
      windowStart: window[0],
      windowEnd: window[1],
      priority: json['priority'] as int? ?? 0,
    );
  }
}

/// 节日日期规则。
sealed class FestivalRule {
  const FestivalRule();

  /// 节日在公历 [year] 内的日期（本地日期，时分秒为 0）；当年没有返回 null。
  DateTime? dateIn(int year);

  factory FestivalRule.fromJson(Map<String, dynamic> json) =>
      switch (json['type']) {
        'lunar' => LunarDateRule(json['month'] as int, json['day'] as int),
        'solarTerm' => SolarTermRule(
          json['name'] as String,
          json['month'] as int,
        ),
        final t => throw FormatException('未知的节日规则: $t'),
      };
}

/// 农历日期（非闰月）。公历年 [year] 内对应的农历年是 year（正月起）；
/// 腊月节日落在次年 1~2 月时取上一个农历年。
class LunarDateRule extends FestivalRule {
  const LunarDateRule(this.month, this.day);
  final int month;
  final int day;

  @override
  DateTime? dateIn(int year) {
    for (final lunarYear in [year, year - 1]) {
      final solar = Lunar.fromYmd(lunarYear, month, day).getSolar();
      if (solar.getYear() == year) {
        return DateTime(solar.getYear(), solar.getMonth(), solar.getDay());
      }
    }
    return null;
  }
}

/// 节气：在公历 [month] 月内查找名为 [name] 的节气日（北京时间）。
class SolarTermRule extends FestivalRule {
  const SolarTermRule(this.name, this.month);
  final String name;
  final int month;

  @override
  DateTime? dateIn(int year) {
    final days = DateTime(year, month + 1, 0).day;
    for (var d = 1; d <= days; d++) {
      if (Lunar.fromSolar(Solar.fromYmd(year, month, d)).getJieQi() == name) {
        return DateTime(year, month, d);
      }
    }
    return null;
  }
}

/// 一次具体的节日窗口。
@immutable
class FestivalOccurrence {
  const FestivalOccurrence(this.festival, this.date, this.start, this.end);

  final FestivalDef festival;

  /// 节日当天、窗口首日、窗口末日（含）。
  final DateTime date;
  final DateTime start;
  final DateTime end;

  /// 本次节日的唯一键（「本次关闭」按它记忆）。
  String get key =>
      '${festival.id}-${date.year}${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  bool contains(DateTime day) => !day.isBefore(start) && !day.isAfter(end);

  @override
  bool operator ==(Object other) =>
      other is FestivalOccurrence && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// 节日日历。
class FestivalCalendar {
  FestivalCalendar._();

  static const String assetPath = 'assets/festivals/festivals.json';

  static List<FestivalDef> _festivals = const [];

  /// 当前时间（测试注入）。
  static DateTime Function() clock = DateTime.now;

  static List<FestivalDef> get all => _festivals;

  static Future<void> load([AssetBundle? bundle]) async {
    try {
      setAll(parse(await (bundle ?? rootBundle).loadString(assetPath)));
    } catch (e) {
      debugPrint('[FestivalCalendar] 节日表加载失败: $e');
    }
  }

  static List<FestivalDef> parse(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return [
      for (final f in json['festivals'] as List)
        FestivalDef.fromJson(f as Map<String, dynamic>),
    ];
  }

  @visibleForTesting
  static void setAll(List<FestivalDef> festivals) {
    _festivals = List.unmodifiable(festivals);
    _cache.clear();
  }

  static final Map<String, FestivalOccurrence?> _cache = {};

  /// [now] 所在本地日期生效的节日（窗口重叠时取优先级最高者）。
  static FestivalOccurrence? activeOn(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final cacheKey = '${day.year}-${day.month}-${day.day}';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
    FestivalOccurrence? best;
    for (final festival in _festivals) {
      // 窗口可能跨公历年（如除夕在 12 月底的极端情况），前后各看一年
      for (final year in [day.year - 1, day.year, day.year + 1]) {
        final date = festival.rule.dateIn(year);
        if (date == null) continue;
        final occurrence = FestivalOccurrence(
          festival,
          date,
          DateTime(date.year, date.month, date.day + festival.windowStart),
          DateTime(date.year, date.month, date.day + festival.windowEnd),
        );
        if (!occurrence.contains(day)) continue;
        if (best == null || festival.priority > best.festival.priority) {
          best = occurrence;
        }
      }
    }
    return _cache[cacheKey] = best;
  }

  /// 下一个本地零点（跨日时重新判定）。
  static DateTime nextMidnight(DateTime now) =>
      DateTime(now.year, now.month, now.day + 1);
}
