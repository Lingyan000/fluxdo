import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:html/dom.dart' as dom;
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:popover/popover.dart';

import '../../../../utils/time_utils.dart';

/// 构建 `discourse-local-date` 本地日期 Widget
///
/// 对应 Discourse cooked HTML 中的 `<span class="discourse-local-date" ...>`，
/// 使用设备本地时区显示，点击弹出多时区预览。
Widget? buildLocalDate({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required double baseFontSize,
}) {
  final dom.Element el = element as dom.Element;
  final opts = _LocalDateOptions.fromElement(el);
  if (opts == null) return null;

  return InlineCustomWidget(
    child: _LocalDateChip(opts: opts, baseFontSize: baseFontSize),
  );
}

class _LocalDateOptions {
  /// Discourse 站点设置 `discourse_local_dates_default_timezones` 的默认值
  ///
  /// 当帖子 `data-timezones` 缺失/为空时，官方前端会用这个默认列表展示多时区预览。
  /// 我们客户端没法读到每个站点的实际设置，按官方默认值兜底。
  static const List<String> _defaultTimezones = [
    'Europe/Paris',
    'America/Los_Angeles',
  ];

  final DateTime localTime;
  final bool hasTime;
  final String? sourceTimezone;
  final String? displayedTimezone;
  final List<String> timezones;
  final String? format;
  final bool countdown;
  final String? range; // "from" | "to" | null

  _LocalDateOptions({
    required this.localTime,
    required this.hasTime,
    this.sourceTimezone,
    this.displayedTimezone,
    this.timezones = const [],
    this.format,
    this.countdown = false,
    this.range,
  });

  static _LocalDateOptions? fromElement(dom.Element el) {
    final date = el.attributes['data-date'];
    if (date == null || date.isEmpty) return null;
    final time = el.attributes['data-time'];
    final timezone = el.attributes['data-timezone'];

    final local = TimeUtils.parseZonedTime(
      date,
      time: time,
      ianaZone: timezone,
    );
    if (local == null) return null;

    final rawTzList = (el.attributes['data-timezones'] ?? '')
        .split('|')
        .where((s) => s.isNotEmpty)
        .toList();
    final tzList = rawTzList.isEmpty ? _defaultTimezones : rawTzList;

    return _LocalDateOptions(
      localTime: local,
      hasTime: time != null && time.isNotEmpty,
      sourceTimezone: timezone,
      displayedTimezone: el.attributes['data-displayed-timezone'],
      timezones: tzList,
      format: el.attributes['data-format'],
      countdown: el.attributes.containsKey('data-countdown'),
      range: el.attributes['data-range'],
    );
  }
}

class _LocalDateChip extends StatefulWidget {
  final _LocalDateOptions opts;
  final double baseFontSize;

  const _LocalDateChip({required this.opts, required this.baseFontSize});

  @override
  State<_LocalDateChip> createState() => _LocalDateChipState();
}

class _LocalDateChipState extends State<_LocalDateChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.opts.countdown) {
      _scheduleCountdownTick();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleCountdownTick() {
    final diff = widget.opts.localTime.difference(DateTime.now());
    // 按距离动态调整刷新频率
    Duration interval;
    if (diff.isNegative) {
      interval = const Duration(minutes: 30);
    } else if (diff.inMinutes < 2) {
      interval = const Duration(seconds: 1);
    } else if (diff.inHours < 1) {
      interval = const Duration(seconds: 15);
    } else if (diff.inHours < 24) {
      interval = const Duration(minutes: 1);
    } else {
      interval = const Duration(minutes: 10);
    }
    _timer = Timer(interval, () {
      if (mounted) {
        setState(() {});
        _scheduleCountdownTick();
      }
    });
  }

  bool get _isPast =>
      DateTime.now().isAfter(widget.opts.localTime);

  String _buildDisplay(BuildContext context) {
    if (widget.opts.countdown) {
      return _formatCountdown(widget.opts.localTime);
    }
    // Discourse 默认 format：有 time 用 LLL，否则 LL
    final fmt = widget.opts.format ??
        (widget.opts.hasTime ? 'LLL' : 'LL');
    return _formatByMomentToken(widget.opts.localTime, fmt,
        chinese: _isChineseLocale(context));
  }

  @override
  Widget build(BuildContext context) {
    if (!TickerMode.valuesOf(context).enabled) {
      _timer?.cancel();
    } else if (widget.opts.countdown &&
        (_timer == null || !_timer!.isActive)) {
      _scheduleCountdownTick();
    }

    final theme = Theme.of(context);
    final past = _isPast;
    final color = past
        ? theme.colorScheme.outline
        : theme.colorScheme.primary;
    final fontSize = widget.baseFontSize;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showTimezonePopover(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: _DashedUnderline(
          color: color.withValues(alpha: 0.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                widget.opts.countdown
                    ? PhosphorIconsRegular.clock
                    : PhosphorIconsRegular.globeHemisphereEast,
                size: fontSize * 0.95,
                color: color,
              ),
              const SizedBox(width: 3),
              Text(
                _buildDisplay(context),
                style: TextStyle(color: color, fontSize: fontSize),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTimezonePopover(BuildContext context) {
    final theme = Theme.of(context);
    showPopover(
      context: context,
      bodyBuilder: (ctx) => _LocalDatePopover(opts: widget.opts),
      direction: PopoverDirection.bottom,
      arrowHeight: 8,
      arrowWidth: 12,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      barrierColor: Colors.transparent,
      radius: 8,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}

class _LocalDatePopover extends StatelessWidget {
  final _LocalDateOptions opts;

  const _LocalDatePopover({required this.opts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chinese = _isChineseLocale(context);
    final entries = _buildTimezoneEntries(chinese: chinese);
    final screenWidth = MediaQuery.of(context).size.width;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: screenWidth * 0.85),
      child: IntrinsicWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < entries.length; i++) ...[
                _buildRow(theme, entries[i]),
                if (i != entries.length - 1)
                  Divider(
                    height: 10,
                    thickness: 0.5,
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.4),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, _TimezoneEntry entry) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: entry.isLocal
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: entry.isLocal
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            entry.formatted,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  List<_TimezoneEntry> _buildTimezoneEntries({required bool chinese}) {
    final list = <_TimezoneEntry>[];
    final localTz = TimeUtils.localTimezone;
    final added = <String>[];

    void addEntry(String tz, {bool isLocal = false}) {
      if (tz.isEmpty) return;
      // 按 UTC offset 去重（Asia/Shanghai 与 Asia/Hong_Kong 在当下视为同一时区）
      if (added.any((a) => TimeUtils.isSameZone(a, tz, at: opts.localTime))) {
        return;
      }
      final converted = TimeUtils.convertToZone(opts.localTime, tz);
      if (converted == null) return;
      added.add(tz);
      final fmt = opts.hasTime ? 'LLLL' : 'LL';
      list.add(_TimezoneEntry(
        label: _zoneShortLabel(tz),
        formatted: _formatByMomentToken(converted, fmt, chinese: chinese),
        isLocal: isLocal,
      ));
    }

    // 本地时区排第一
    addEntry(localTz, isLocal: true);
    // 源时区
    if (opts.sourceTimezone != null) addEntry(opts.sourceTimezone!);
    // 预览时区
    for (final tz in opts.timezones) {
      addEntry(tz);
    }

    return list;
  }

  static String _zoneShortLabel(String tz) {
    // Etc/UTC → UTC；Asia/Shanghai → Shanghai
    final cleaned = tz.replaceAll('Etc/', '').replaceAll('_', ' ');
    final parts = cleaned.split('/');
    return parts.length > 1 ? parts.last : parts.first;
  }
}

class _TimezoneEntry {
  final String label;
  final String formatted;
  final bool isLocal;

  _TimezoneEntry({
    required this.label,
    required this.formatted,
    required this.isLocal,
  });
}

/// 虚线底边装饰器（对应 Discourse .cooked-date 的 dashed underline）
class _DashedUnderline extends StatelessWidget {
  final Color color;
  final Widget child;

  const _DashedUnderline({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedLinePainter(color: color),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: child,
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;

  _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dashWidth = 2.0;
    const dashSpace = 2.0;
    double x = 0;
    final y = size.height - 0.5;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x + dashWidth, y),
        paint,
      );
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter old) => old.color != color;
}

// ---------- 格式化辅助 ----------

/// 判断当前 locale 是否是中文
bool _isChineseLocale(BuildContext context) {
  return Localizations.localeOf(context).languageCode == 'zh';
}

/// 把 moment.js 常用 token 映射到本地化格式
///
/// 覆盖 `LT` `LTS` `L` `LL` `LLL` `LLLL`，其他 token fallback 到
/// `formatDetailTime`。中文按 moment.js zh-cn locale 对齐：
/// - `LL`  → "2026年4月1日"
/// - `LLL` → "2026年4月1日晚上10点22分"
/// - `LLLL`→ "2026年4月1日星期三晚上10点22分"
String _formatByMomentToken(
  DateTime time,
  String? format, {
  required bool chinese,
}) {
  switch (format) {
    case 'L':
      return chinese
          ? DateFormat('yyyy/M/d').format(time)
          : DateFormat('yyyy-MM-dd').format(time);
    case 'LT':
      return DateFormat('HH:mm').format(time);
    case 'LTS':
      return DateFormat('HH:mm:ss').format(time);
    case null:
    case '':
    case 'LL':
      return chinese
          ? '${time.year}年${time.month}月${time.day}日'
          : DateFormat.yMMMMd().format(time);
    case 'LLL':
      if (chinese) {
        return '${time.year}年${time.month}月${time.day}日'
            '${_zhMeridiem(time)}${_zhHour12(time.hour)}点'
            '${time.minute.toString().padLeft(2, '0')}分';
      }
      return '${DateFormat.yMMMMd().format(time)} '
          '${DateFormat.jm().format(time)}';
    case 'LLLL':
      if (chinese) {
        return '${time.year}年${time.month}月${time.day}日'
            '${_zhWeekday(time)}${_zhMeridiem(time)}${_zhHour12(time.hour)}点'
            '${time.minute.toString().padLeft(2, '0')}分';
      }
      return '${DateFormat.EEEE().format(time)} '
          '${DateFormat.yMMMMd().format(time)} '
          '${DateFormat.jm().format(time)}';
    default:
      return TimeUtils.formatDetailTime(time);
  }
}

/// moment.js zh-cn 的 6 段 meridiem
String _zhMeridiem(DateTime t) {
  final hm = t.hour * 100 + t.minute;
  if (hm < 600) return '凌晨';
  if (hm < 900) return '早上';
  if (hm < 1130) return '上午';
  if (hm < 1230) return '中午';
  if (hm < 1800) return '下午';
  return '晚上';
}

/// 24 小时制转 12 小时制（0/12 → 12）
int _zhHour12(int h) {
  if (h == 0 || h == 12) return 12;
  return h > 12 ? h - 12 : h;
}

/// 中文星期
String _zhWeekday(DateTime t) {
  const names = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  return names[t.weekday - 1];
}

/// 倒计时文案
///
/// 对齐 Discourse 官方行为：未到按 duration 显示（"3 小时"），已过固定为"已过"。
String _formatCountdown(DateTime target) {
  final diff = target.difference(DateTime.now());
  if (diff.isNegative) return '已过';
  if (diff.inMinutes < 1) return '即将开始';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟';
  if (diff.inDays < 1) return '${diff.inHours} 小时';
  if (diff.inDays < 30) return '${diff.inDays} 天';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()} 个月';
  return '${(diff.inDays / 365).floor()} 年';
}
