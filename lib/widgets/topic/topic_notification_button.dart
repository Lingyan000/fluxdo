import 'package:flutter/material.dart';

import '../../models/category.dart';
import '../../models/topic.dart';
import '../common/notification_level_button.dart';

enum TopicNotificationButtonStyle { icon, chip }

class TopicNotificationButton extends StatelessWidget {
  const TopicNotificationButton({
    super.key,
    required this.level,
    this.onChanged,
    this.isLoading = false,
    this.style = TopicNotificationButtonStyle.icon,
  });

  final TopicNotificationLevel level;
  final ValueChanged<TopicNotificationLevel>? onChanged;
  final bool isLoading;
  final TopicNotificationButtonStyle style;

  static IconData getIcon(TopicNotificationLevel level) =>
      notificationLevelIcon(level.value);

  @override
  Widget build(BuildContext context) {
    if (style == TopicNotificationButtonStyle.chip) {
      return _buildChip(context);
    }
    return NotificationLevelButton(
      level: level.value,
      label: level.label,
      isLoading: isLoading,
      onPressed: onChanged == null ? null : () => _showSheet(context),
    );
  }

  /// AI 摘要卡片内的胶囊样式订阅入口。
  Widget _buildChip(BuildContext context) {
    final theme = Theme.of(context);
    final isWatching =
        level == TopicNotificationLevel.watching ||
        level == TopicNotificationLevel.tracking;

    // 适配 AI 摘要按钮风格
    final bgColor = isWatching
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.primaryContainer.withValues(alpha: 0.3);

    final fgColor = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onChanged != null ? () => _showSheet(context) : null,
        borderRadius: BorderRadius.circular(8), // 统一圆角为 8
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ), // 统一 Padding
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isWatching
                  ? theme.colorScheme.primary
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(getIcon(level), size: 16, color: fgColor),
              const SizedBox(width: 6),
              Text(
                level.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w500, // 统一字重
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSheet(BuildContext context) {
    if (onChanged == null) return;
    showNotificationLevelSheet(context, level, onChanged!);
  }
}

void showNotificationLevelSheet(
  BuildContext context,
  TopicNotificationLevel currentLevel,
  ValueChanged<TopicNotificationLevel> onSelected,
) {
  showNotificationLevelSelectionSheet(
    context: context,
    currentLevel: currentLevel,
    options: [
      for (final level in TopicNotificationLevel.values)
        NotificationLevelOption(
          value: level,
          icon: TopicNotificationButton.getIcon(level),
          label: level.label,
          description: level.description,
        ),
    ],
    onSelected: onSelected,
  );
}

class CategoryNotificationButton extends StatelessWidget {
  const CategoryNotificationButton({
    super.key,
    required this.level,
    this.onChanged,
    this.isLoading = false,
  });

  final CategoryNotificationLevel level;
  final ValueChanged<CategoryNotificationLevel>? onChanged;
  final bool isLoading;

  @override
  Widget build(BuildContext context) => NotificationLevelButton(
    level: level.value,
    label: level.label,
    isLoading: isLoading,
    onPressed: onChanged == null
        ? null
        : () => showCategoryNotificationLevelSheet(context, level, onChanged!),
  );
}

IconData getCategoryNotificationIcon(CategoryNotificationLevel level) =>
    notificationLevelIcon(level.value);

/// 分类详情页与侧栏共用的订阅选择入口。
void showCategoryNotificationLevelSheet(
  BuildContext context,
  CategoryNotificationLevel currentLevel,
  ValueChanged<CategoryNotificationLevel> onSelected,
) {
  showNotificationLevelSelectionSheet(
    context: context,
    currentLevel: currentLevel,
    options: [
      for (final level in CategoryNotificationLevel.values)
        NotificationLevelOption(
          value: level,
          icon: getCategoryNotificationIcon(level),
          label: level.label,
          description: level.description,
        ),
    ],
    onSelected: onSelected,
  );
}
