import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import 'app_bottom_sheet.dart';

/// 分类、标签和话题共用的顶部订阅入口。
class NotificationLevelButton extends StatelessWidget {
  const NotificationLevelButton({
    super.key,
    required this.level,
    required this.label,
    this.onPressed,
    this.isLoading = false,
    this.errorTooltip,
  });

  final int? level;
  final String? label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final String? errorTooltip;

  @override
  Widget build(BuildContext context) {
    final title = context.l10n.topic_notificationSettings;
    return IconButton(
      tooltip: errorTooltip ?? (label == null ? title : '$title: $label'),
      onPressed: isLoading ? null : onPressed,
      color: errorTooltip == null && (level ?? 1) >= 2
          ? Theme.of(context).colorScheme.primary
          : null,
      icon: isLoading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              errorTooltip == null
                  ? notificationLevelIcon(level)
                  : Symbols.sync_problem_rounded,
            ),
    );
  }
}

IconData notificationLevelIcon(int? level) => switch (level) {
  0 => Symbols.notifications_off_rounded,
  2 => Symbols.notifications_rounded,
  3 => Symbols.notifications_active_rounded,
  4 => Symbols.notification_add_rounded,
  _ => Symbols.notifications_none_rounded,
};

class NotificationLevelOption<T> {
  const NotificationLevelOption({
    required this.value,
    required this.icon,
    required this.label,
    required this.description,
  });

  final T value;
  final IconData icon;
  final String label;
  final String description;
}

/// 页面、侧栏和快捷手势共用的订阅选择面板。
void showNotificationLevelSelectionSheet<T>({
  required BuildContext context,
  required T currentLevel,
  required List<NotificationLevelOption<T>> options,
  required ValueChanged<T> onSelected,
}) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return AppSheetScaffold(
        title: sheetContext.l10n.topic_notificationSettings,
        showCloseButton: false,
        contentPadding: EdgeInsets.zero,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((option) {
              final isSelected = option.value == currentLevel;
              return ListTile(
                leading: Icon(
                  option.icon,
                  color: isSelected ? theme.colorScheme.primary : null,
                ),
                title: Text(
                  option.label,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? theme.colorScheme.primary : null,
                  ),
                ),
                subtitle: Text(
                  option.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: isSelected
                    ? Icon(
                        Symbols.check_rounded,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (option.value != currentLevel) onSelected(option.value);
                },
              );
            }).toList(),
          ),
        ),
      );
    },
  );
}
