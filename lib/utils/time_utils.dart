import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/s.dart';

/// 时间工具类 - 统一处理时间格式化和时区转换
class TimeUtils {
  TimeUtils._();

  static String _localTimezone = 'UTC';
  static bool _tzInitialized = false;

  /// 设备本地 IANA 时区名（如 "Asia/Shanghai"）
  ///
  /// `initialize()` 执行前返回 "UTC"。
  static String get localTimezone => _localTimezone;

  /// 初始化时区数据库和本地时区
  ///
  /// 在 main() 中尽早调用。失败时回退到 UTC，不抛异常。
  static Future<void> initialize() async {
    if (_tzInitialized) return;
    tzdata.initializeTimeZones();
    _tzInitialized = true;
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      final name = info.identifier;
      tz.setLocalLocation(tz.getLocation(name));
      _localTimezone = name;
    } catch (e) {
      debugPrint('[TimeUtils] 获取本地时区失败，回退 UTC: $e');
    }
  }

  /// 解析 UTC 时间字符串并转换为本地时间
  /// Discourse API 返回的时间是 UTC 格式
  static DateTime? parseUtcTime(String? timeString) {
    if (timeString == null || timeString.isEmpty) return null;

    try {
      // 解析为 UTC 时间
      final utcTime = DateTime.parse(timeString);
      // 转换为本地时间
      return utcTime.toLocal();
    } catch (e) {
      return null;
    }
  }

  /// 解析带 IANA 时区的日期时间，返回本地 DateTime
  ///
  /// - [date]: "YYYY-MM-DD" 格式
  /// - [time]: "HH:mm:ss" / "HH:mm" 格式，可选
  /// - [ianaZone]: IANA 时区名（如 "Asia/Shanghai"），不识别或为空时按 UTC 处理
  ///
  /// 用于解析 `discourse-local-date` 的 `data-date` + `data-time` + `data-timezone`。
  static DateTime? parseZonedTime(
    String? date, {
    String? time,
    String? ianaZone,
  }) {
    if (date == null || date.isEmpty) return null;
    try {
      final dateParts = date.split('-');
      if (dateParts.length < 3) return null;
      final y = int.parse(dateParts[0]);
      final m = int.parse(dateParts[1]);
      final d = int.parse(dateParts[2]);

      var hour = 0, minute = 0, second = 0;
      if (time != null && time.isNotEmpty) {
        final tp = time.split(':');
        if (tp.isNotEmpty) hour = int.tryParse(tp[0]) ?? 0;
        if (tp.length > 1) minute = int.tryParse(tp[1]) ?? 0;
        if (tp.length > 2) second = int.tryParse(tp[2]) ?? 0;
      }

      tz.Location location;
      try {
        location = tz.getLocation(
          (ianaZone == null || ianaZone.isEmpty) ? 'Etc/UTC' : ianaZone,
        );
      } catch (_) {
        location = tz.getLocation('Etc/UTC');
      }

      final tzDt = tz.TZDateTime(location, y, m, d, hour, minute, second);
      return DateTime.fromMillisecondsSinceEpoch(tzDt.millisecondsSinceEpoch);
    } catch (_) {
      return null;
    }
  }

  /// 将本地 DateTime 以指定 IANA 时区格式化
  ///
  /// 用于多时区预览（如 tooltip 里显示东京、纽约对应时间）。
  static DateTime? convertToZone(DateTime? time, String ianaZone) {
    if (time == null) return null;
    try {
      final loc = tz.getLocation(ianaZone);
      final tzDt = tz.TZDateTime.from(time, loc);
      // 使用 TZDateTime 的 year/month/day/... 字段构造一个“墙上时间”DateTime
      return DateTime(
        tzDt.year,
        tzDt.month,
        tzDt.day,
        tzDt.hour,
        tzDt.minute,
        tzDt.second,
      );
    } catch (_) {
      return null;
    }
  }

  /// 判断两个 IANA 时区在给定时刻是否等价
  ///
  /// 对齐 Discourse `_isEqualZones`：
  /// 1. 字符串相等或包含关系（如 "Asia/Shanghai" 与 "Shanghai"）
  /// 2. 在指定时刻的 UTC 偏移相同（考虑 DST）
  ///
  /// [at] 不传则用当前时刻，与 moment.tz(zone).utcOffset() 的行为一致。
  static bool isSameZone(String? a, String? b, {DateTime? at}) {
    if (a == null || b == null) return false;
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (a.contains(b) || b.contains(a)) return true;
    try {
      final locA = tz.getLocation(a);
      final locB = tz.getLocation(b);
      final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
      return locA.timeZone(ms).offset == locB.timeZone(ms).offset;
    } catch (_) {
      return false;
    }
  }

  /// 格式化时间为相对时间（刚刚、X分钟前、X小时前等）
  /// 适用于列表页等需要简洁显示的场景
  static String formatRelativeTime(DateTime? time) {
    if (time == null) return '';

    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) return S.current.time_justNow;
    if (diff.inMinutes < 60) return S.current.time_minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return S.current.time_hoursAgo(diff.inHours);
    if (diff.inDays < 7) return S.current.time_daysAgo(diff.inDays);
    if (diff.inDays < 30) return S.current.time_weeksAgo((diff.inDays / 7).floor());
    if (diff.inDays < 365) return S.current.time_monthsAgo((diff.inDays / 30).floor());
    return S.current.time_yearsAgo((diff.inDays / 365).floor());
  }

  /// 格式化时间为详细时间字符串
  /// 格式：2024-01-15 14:30
  /// 适用于详情页等需要精确时间的场景
  static String formatDetailTime(DateTime? time) {
    if (time == null) return '';

    final formatter = DateFormat('yyyy-MM-dd HH:mm');
    return formatter.format(time);
  }

  /// 格式化时间为短日期
  /// 格式：1月15日
  static String formatShortDate(DateTime? time) {
    if (time == null) return '';

    return S.current.time_shortDate(time.month, time.day);
  }

  /// 格式化时间为完整日期
  /// 格式：2024年1月15日
  static String formatFullDate(DateTime? time) {
    if (time == null) return '';

    return S.current.time_fullDate(time.year, time.month, time.day);
  }

  /// 格式化时间为 Tooltip 精确时间
  /// 格式：2024年1月15日 14:30:25
  /// 适用于长按显示精确时间的场景
  static String formatTooltipTime(DateTime? time) {
    if (time == null) return '';

    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return S.current.time_tooltipTime(time.year, time.month, time.day, hh, mm, ss);
  }

  /// 格式化时间为智能日期标签
  /// 今天显示"今天"、昨天显示"昨天"、同年显示"1月15日"、跨年显示"2024年1月15日"
  static String formatSmartDate(DateTime? time) {
    if (time == null) return '';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(time.year, time.month, time.day);

    if (date == today) return S.current.time_today;
    if (date == today.subtract(const Duration(days: 1))) return S.current.time_yesterday;
    if (time.year == now.year) return S.current.time_shortDate(time.month, time.day);
    return S.current.time_fullDate(time.year, time.month, time.day);
  }

  /// 格式化时间为紧凑格式
  /// 格式：01-15 14:30
  /// 适用于聊天引用等空间有限的场景
  static String formatCompactTime(DateTime? time) {
    if (time == null) return '';

    final formatter = DateFormat('MM-dd HH:mm');
    return formatter.format(time);
  }

  /// 时:分(聊天气泡内联时间;日期已由分隔线承载)
  static String formatClockTime(DateTime? time) {
    if (time == null) return '';
    return DateFormat('HH:mm').format(time);
  }
}
