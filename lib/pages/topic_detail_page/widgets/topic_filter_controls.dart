import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';

/// 帖子筛选的当前状态与切换入口（底栏、宽屏阅读栏共用）
@immutable
class TopicFilterControls {
  const TopicFilterControls({
    this.hasSummary = false,
    this.isPostVoting = false,
    this.isSummaryMode = false,
    this.isActivityMode = false,
    this.isAuthorOnlyMode = false,
    this.isTopLevelMode = false,
    this.isNestedMode = false,
    this.isLoading = false,
    this.onShowTopReplies,
    this.onShowByActivity,
    this.onShowAuthorOnly,
    this.onShowTopLevelReplies,
    this.onCancelFilter,
    this.onShowNestedView,
  });

  final bool hasSummary;
  final bool isPostVoting;
  final bool isSummaryMode;
  final bool isActivityMode;
  final bool isAuthorOnlyMode;
  final bool isTopLevelMode;
  final bool isNestedMode;
  final bool isLoading;
  final VoidCallback? onShowTopReplies;
  final VoidCallback? onShowByActivity;
  final VoidCallback? onShowAuthorOnly;
  final VoidCallback? onShowTopLevelReplies;
  final VoidCallback? onCancelFilter;
  final VoidCallback? onShowNestedView;

  bool get hasActiveFilter =>
      isSummaryMode ||
      isActivityMode ||
      isAuthorOnlyMode ||
      isTopLevelMode ||
      isNestedMode;

  (IconData, String) active(BuildContext context) {
    final l10n = context.l10n;
    if (isSummaryMode) {
      return (Symbols.local_fire_department_rounded, l10n.topicDetail_hotOnly);
    }
    if (isActivityMode) {
      return (Symbols.history_rounded, l10n.topicDetail_sortByActivity);
    }
    if (isAuthorOnlyMode) {
      return (Symbols.person_rounded, l10n.topicDetail_authorOnly);
    }
    if (isTopLevelMode) {
      return (Symbols.account_tree_rounded, l10n.topicDetail_topLevelOnly);
    }
    if (isNestedMode) return (Symbols.forum_rounded, l10n.nested_title);
    return (Symbols.filter_list_rounded, l10n.topicDetail_filter);
  }
}

/// 筛选按钮：未激活时弹出筛选菜单，激活时高亮当前模式、点按取消。
/// [showLabel] 为 true 时带文字（宽屏阅读栏），否则只有图标（底栏）。
class TopicFilterButton extends StatelessWidget {
  const TopicFilterButton({
    super.key,
    required this.controls,
    this.showLabel = false,
    this.openOnPress = true,
  });

  final TopicFilterControls controls;
  final bool showLabel;
  final bool openOnPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controls;
    if (c.hasActiveFilter) {
      final (icon, label) = c.active(context);
      final onPressed = c.isLoading ? null : c.onCancelFilter;
      if (showLabel) {
        return FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              const Icon(Symbols.close_rounded, size: 16),
            ],
          ),
        );
      }
      return IconButton(
        onPressed: onPressed,
        tooltip: label,
        icon: Icon(icon, color: context.emphasis.accent),
        style: IconButton.styleFrom(
          backgroundColor: theme.colorScheme.primaryContainer,
        ),
        visualDensity: VisualDensity.compact,
      );
    }

    return SwipeDismissiblePopupMenuButton<String>(
      openOnPress: openOnPress,
      enabled: !c.isLoading,
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: showLabel ? null : const Icon(Symbols.filter_list_rounded),
      iconColor: theme.colorScheme.onSurfaceVariant,
      tooltip: context.l10n.topicDetail_filter,
      onSelected: (value) {
        switch (value) {
          case 'hot':
            c.onShowTopReplies?.call();
          case 'activity':
            c.onShowByActivity?.call();
          case 'author':
            c.onShowAuthorOnly?.call();
          case 'top_level':
            c.onShowTopLevelReplies?.call();
          case 'nested':
            c.onShowNestedView?.call();
        }
      },
      itemBuilder: (context) => [
        if (c.isPostVoting)
          _menuItem(
            theme,
            'activity',
            Symbols.history_rounded,
            context.l10n.topicDetail_sortByActivity,
          ),
        if (c.hasSummary)
          _menuItem(
            theme,
            'hot',
            Symbols.local_fire_department_rounded,
            context.l10n.topicDetail_hotOnly,
          ),
        _menuItem(
          theme,
          'author',
          Symbols.person_rounded,
          context.l10n.topicDetail_authorOnly,
        ),
        _menuItem(
          theme,
          'top_level',
          Symbols.account_tree_rounded,
          context.l10n.topicDetail_topLevelOnly,
        ),
        const PopupMenuDivider(),
        _menuItem(
          theme,
          'nested',
          Symbols.forum_rounded,
          context.l10n.nested_title,
        ),
      ],
      child: showLabel
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.filter_list_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.topicDetail_filter,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  PopupMenuItem<String> _menuItem(
    ThemeData theme,
    String value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurface),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }
}
