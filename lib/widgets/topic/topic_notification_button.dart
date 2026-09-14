import 'package:flutter/material.dart';

import '../../models/category.dart';
import '../../models/topic.dart';
import '../common/notification_level_button.dart';

class TopicNotificationButton extends StatelessWidget {
  const TopicNotificationButton({
    super.key,
    required this.level,
    this.onChanged,
    this.isLoading = false,
  });

  final TopicNotificationLevel level;
  final ValueChanged<TopicNotificationLevel>? onChanged;
  final bool isLoading;

  static IconData getIcon(TopicNotificationLevel level) =>
      notificationLevelIcon(level.value);

  @override
  Widget build(BuildContext context) => NotificationLevelButton(
    level: level.value,
    label: level.label,
    isLoading: isLoading,
    onPressed: onChanged == null
        ? null
        : () => showNotificationLevelSheet(context, level, onChanged!),
  );
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
