import 'package:flutter/material.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../utils/dialog_utils.dart';
import '../../../../../l10n/s.dart';

enum TopicNotificationButtonStyle {
  icon,
  chip,
}

/// 显示订阅级别选择面板
void showNotificationLevelSheet(
  BuildContext context,
  TopicNotificationLevel currentLevel,
  ValueChanged<TopicNotificationLevel> onSelected,
) {
  showAppBottomSheet(
    context: context,
    builder: (context) => _NotificationLevelSheet(
      currentLevel: currentLevel,
      onSelected: (newLevel) {
        Navigator.pop(context);
        onSelected(newLevel);
      },
    ),
  );
}

class TopicNotificationButton extends StatelessWidget {
  final TopicNotificationLevel level;
  final ValueChanged<TopicNotificationLevel>? onChanged;
  final TopicNotificationButtonStyle style;

  const TopicNotificationButton({
    super.key,
    required this.level,
    this.onChanged,
    this.style = TopicNotificationButtonStyle.icon,
  });

  static IconData getIcon(TopicNotificationLevel level) {
    switch (level) {
      case TopicNotificationLevel.muted:
        return Icons.notifications_off_outlined;
      case TopicNotificationLevel.regular:
        return Icons.notifications_none_outlined;
      case TopicNotificationLevel.tracking:
        return Icons.notifications_outlined;
      case TopicNotificationLevel.watching:
        return Icons.notifications_active;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (style == TopicNotificationButtonStyle.chip) {
      return _buildChip(context);
    }
    return _buildIconButton(context);
  }

  Widget _buildChip(BuildContext context) {
    final theme = Theme.of(context);
    final isWatching = level == TopicNotificationLevel.watching || 
                       level == TopicNotificationLevel.tracking;
    
    // 适配 AI 摘要按钮风格
    final bgColor = isWatching 
        ? theme.colorScheme.primaryContainer 
        : theme.colorScheme.primaryContainer.withValues(alpha:0.3);
    
    final fgColor = isWatching 
        ? theme.colorScheme.primary 
        : theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onChanged != null ? () => _showSheet(context) : null,
        borderRadius: BorderRadius.circular(8), // 统一圆角为 8
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // 统一 Padding
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isWatching ? theme.colorScheme.primary : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                getIcon(level),
                size: 16,
                color: fgColor,
              ),
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

  Widget _buildIconButton(BuildContext context) {
    return IconButton(
      onPressed: onChanged != null ? () => _showSheet(context) : null,
      icon: Icon(getIcon(level)),
      tooltip: level.label,
    );
  }

  void _showSheet(BuildContext context) {
    if (onChanged == null) return;
    showNotificationLevelSheet(context, level, onChanged!);
  }
}

class _NotificationLevelSheet extends StatelessWidget {
  final TopicNotificationLevel currentLevel;
  final ValueChanged<TopicNotificationLevel> onSelected;

  const _NotificationLevelSheet({
    required this.currentLevel,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              S.current.topic_notificationSettings,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ...TopicNotificationLevel.values.map((level) {
            final isSelected = level == currentLevel;
            return ListTile(
              leading: Icon(
                TopicNotificationButton.getIcon(level),
                color: isSelected ? theme.colorScheme.primary : null,
              ),
              title: Text(
                level.label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? theme.colorScheme.primary : null,
                ),
              ),
              subtitle: Text(
                level.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: isSelected
                  ? Icon(Icons.check, color: theme.colorScheme.primary)
                  : null,
              onTap: () => onSelected(level),
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ============================================================
// 分类通知级别按钮（5 个选项，多一个 watchingFirstPost）
// ============================================================

/// 获取分类通知级别对应的图标
IconData getCategoryNotificationIcon(CategoryNotificationLevel level) {
  switch (level) {
    case CategoryNotificationLevel.muted:
      return Icons.notifications_off_outlined;
    case CategoryNotificationLevel.regular:
      return Icons.notifications_none_outlined;
    case CategoryNotificationLevel.tracking:
      return Icons.notifications_outlined;
    case CategoryNotificationLevel.watching:
      return Icons.notifications_active;
    case CategoryNotificationLevel.watchingFirstPost:
      return Icons.notification_add_outlined;
  }
}

/// 分类订阅按钮（chip 样式）
class CategoryNotificationButton extends StatelessWidget {
  final CategoryNotificationLevel level;
  final ValueChanged<CategoryNotificationLevel>? onChanged;

  const CategoryNotificationButton({
    super.key,
    required this.level,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMuted = level == CategoryNotificationLevel.muted;
    final isWatching = level == CategoryNotificationLevel.watching ||
        level == CategoryNotificationLevel.tracking ||
        level == CategoryNotificationLevel.watchingFirstPost;

    final Color bgColor;
    final Color fgColor;
    final Color borderColor;

    if (isMuted) {
      bgColor = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
      fgColor = theme.colorScheme.onSurfaceVariant;
      borderColor = Colors.transparent;
    } else if (isWatching) {
      bgColor = theme.colorScheme.primaryContainer;
      fgColor = theme.colorScheme.primary;
      borderColor = theme.colorScheme.primary;
    } else {
      // regular
      bgColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.3);
      fgColor = theme.colorScheme.primary;
      borderColor = Colors.transparent;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onChanged != null ? () => _showSheet(context) : null,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                getCategoryNotificationIcon(level),
                size: 14,
                color: fgColor,
              ),
              const SizedBox(width: 4),
              Text(
                level.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w500,
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
    showAppBottomSheet(
      context: context,
      builder: (context) => _CategoryNotificationLevelSheet(
        currentLevel: level,
        onSelected: (newLevel) {
          Navigator.pop(context);
          onChanged!(newLevel);
        },
      ),
    );
  }
}

class _CategoryNotificationLevelSheet extends StatelessWidget {
  final CategoryNotificationLevel currentLevel;
  final ValueChanged<CategoryNotificationLevel> onSelected;

  const _CategoryNotificationLevelSheet({
    required this.currentLevel,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              S.current.topic_notificationSettings,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: CategoryNotificationLevel.values.map((level) {
                  final isSelected = level == currentLevel;
                  return ListTile(
                    leading: Icon(
                      getCategoryNotificationIcon(level),
                      color: isSelected ? theme.colorScheme.primary : null,
                    ),
                    title: Text(
                      level.label,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : null,
                      ),
                    ),
                    subtitle: Text(
                      level.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => onSelected(level),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
