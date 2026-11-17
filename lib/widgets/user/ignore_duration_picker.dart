import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../common/app_bottom_sheet.dart';

/// 显示忽略时长选择弹窗，返回 expiringAt（ISO8601 UTC 字符串），取消返回 null。
///
/// 选项与 Discourse 前端 extendedDefaultTimeShortcuts 保持一致。
/// 由用户个人页与用户卡片共用。
Future<String?> showIgnoreDurationPicker(BuildContext context) {
  final now = DateTime.now();
  final weekdays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String formatTarget(DateTime target) {
    // 永久不显示时间
    if (target.year - now.year > 100) return '';
    final h = target.hour.toString().padLeft(2, '0');
    final m = target.minute.toString().padLeft(2, '0');
    final time = '$h:$m';
    // 同一天只显示时间
    if (target.day == now.day &&
        target.month == now.month &&
        target.year == now.year) {
      return time;
    }
    // 同年显示 月日 周几 时间
    if (target.year == now.year) {
      return '${S.current.time_shortDate(target.month, target.day)} ${weekdays[target.weekday]} $time';
    }
    // 跨年显示完整日期
    return '${S.current.time_fullDate(target.year, target.month, target.day)} $time';
  }

  final options = <(String, Duration)>[
    if (now.hour < 18)
      (S.current.userProfile_laterToday, Duration(hours: 18 - now.hour)),
    (S.current.userProfile_tomorrow, Duration(days: 1)),
    if (now.weekday <= DateTime.wednesday)
      (
        S.current.userProfile_laterThisWeek,
        Duration(days: DateTime.thursday - now.weekday),
      ),
    (
      S.current.userProfile_nextMonday,
      Duration(
        days: (DateTime.monday - now.weekday + 7) % 7 == 0
            ? 7
            : (DateTime.monday - now.weekday + 7) % 7,
      ),
    ),
    (S.current.userProfile_twoWeeks, Duration(days: 14)),
    (S.current.userProfile_nextMonth, Duration(days: 30)),
    (S.current.userProfile_twoMonths, Duration(days: 60)),
    (S.current.userProfile_threeMonths, Duration(days: 90)),
    (S.current.userProfile_fourMonths, Duration(days: 120)),
    (S.current.userProfile_sixMonths, Duration(days: 180)),
    (S.current.userProfile_oneYear, Duration(days: 365)),
    (S.current.userProfile_permanent, Duration(days: 365000)),
  ];

  return AppBottomSheet.show<String>(
    context: context,
    title: S.current.userProfile_selectIgnoreDuration,
    showCloseButton: false,
    contentPadding: EdgeInsets.zero,
    builder: (context) {
      final theme = Theme.of(context);
      return ListView(
        shrinkWrap: true,
        children: options.map((option) {
          final target = now.add(option.$2);
          final desc = formatTarget(target);
          return ListTile(
            title: Text(option.$1),
            trailing: desc.isNotEmpty
                ? Text(
                    desc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : null,
            onTap: () {
              final expiry = DateTime.now().toUtc().add(option.$2);
              Navigator.pop(context, expiry.toIso8601String());
            },
          );
        }).toList(),
      );
    },
  );
}
