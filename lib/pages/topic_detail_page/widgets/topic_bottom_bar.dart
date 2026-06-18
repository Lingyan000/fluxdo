import 'package:flutter/material.dart';
import '../../../l10n/s.dart';
import 'package:common_ui/common_ui.dart';

/// 话题详情页底部操作栏
class TopicBottomBar extends StatelessWidget {
  final VoidCallback? onScrollToTop;
  final VoidCallback? onShare;
  final VoidCallback? onShareAsImage;
  final VoidCallback? onExport;
  final VoidCallback? onOpenInBrowser;
  final bool hasSummary;
  final bool isSummaryMode;
  final bool isAuthorOnlyMode;
  final bool isTopLevelMode;
  final bool isNestedMode;
  final bool isLoading;
  final VoidCallback? onShowTopReplies;
  final VoidCallback? onShowAuthorOnly;
  final VoidCallback? onShowTopLevelReplies;
  final VoidCallback? onCancelFilter;
  final VoidCallback? onShowNestedView;
  final bool isPrivateMessage;

  const TopicBottomBar({
    super.key,
    this.onScrollToTop,
    this.onShare,
    this.onShareAsImage,
    this.onExport,
    this.onOpenInBrowser,
    this.hasSummary = false,
    this.isSummaryMode = false,
    this.isAuthorOnlyMode = false,
    this.isTopLevelMode = false,
    this.isNestedMode = false,
    this.isLoading = false,
    this.isPrivateMessage = false,
    this.onShowTopReplies,
    this.onShowAuthorOnly,
    this.onShowTopLevelReplies,
    this.onCancelFilter,
    this.onShowNestedView,
  });

  bool get _hasActiveFilter => isSummaryMode || isAuthorOnlyMode || isTopLevelMode || isNestedMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      height: 80,
      padding: EdgeInsets.only(bottom: bottomPadding),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          // 回到顶部
          IconButton(
            onPressed: onScrollToTop,
            icon: const Icon(Icons.vertical_align_top),
            tooltip: context.l10n.topicDetail_scrollToTop,
          ),
          // 筛选
          if (_hasActiveFilter)
            _buildActiveFilterChip(context, theme)
          else
            _buildFilterMenuButton(context, theme),
          // 分享菜单
          _buildShareMenu(context, theme),
          // 在浏览器打开
          IconButton(
            onPressed: onOpenInBrowser,
            icon: const Icon(Icons.language),
            tooltip: context.l10n.topicDetail_openInBrowser,
          ),
        ],
      ),
    );
  }

  /// 激活态：紧凑图标按钮 + 小关闭按钮
  Widget _buildActiveFilterChip(BuildContext context, ThemeData theme) {
    final (icon, _) = _activeFilterInfo(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: isLoading ? null : onCancelFilter,
          icon: Icon(icon, color: theme.colorScheme.primary),
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.primaryContainer,
          ),
          iconSize: 20,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  (IconData, String) _activeFilterInfo(BuildContext context) {
    if (isSummaryMode) return (Icons.local_fire_department, context.l10n.topicDetail_hotOnly);
    if (isAuthorOnlyMode) return (Icons.person, context.l10n.topicDetail_authorOnly);
    if (isTopLevelMode) return (Icons.account_tree, context.l10n.topicDetail_topLevelOnly);
    if (isNestedMode) return (Icons.forum, context.l10n.nested_title);
    return (Icons.filter_list, '');
  }

  /// 未激活：筛选菜单按钮
  Widget _buildFilterMenuButton(BuildContext context, ThemeData theme) {
    return SwipeDismissiblePopupMenuButton<String>(
      enabled: !isLoading,
      icon: const Icon(Icons.filter_list),
      iconColor: theme.colorScheme.onSurfaceVariant,
      tooltip: context.l10n.topicDetail_filter,
      onSelected: (value) {
        switch (value) {
          case 'hot':
            onShowTopReplies?.call();
          case 'author':
            onShowAuthorOnly?.call();
          case 'top_level':
            onShowTopLevelReplies?.call();
          case 'nested':
            onShowNestedView?.call();
        }
      },
      itemBuilder: (context) => [
        if (hasSummary)
          PopupMenuItem(
            value: 'hot',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_fire_department_outlined,
                    size: 20, color: theme.colorScheme.onSurface),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_hotOnly),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'author',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline,
                  size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_authorOnly),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'top_level',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_topLevelOnly),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'nested',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined,
                  size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(width: 12),
              Text(context.l10n.nested_title),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShareMenu(BuildContext context, ThemeData theme) {
    return SwipeDismissiblePopupMenuButton<String>(
      icon: const Icon(Icons.share_outlined),
      iconColor: theme.colorScheme.onSurfaceVariant,
      tooltip: context.l10n.common_share,
      onSelected: (value) {
        switch (value) {
          case 'link':
            onShare?.call();
            break;
          case 'image':
            onShareAsImage?.call();
            break;
          case 'export':
            onExport?.call();
            break;
        }
      },
      itemBuilder: (context) => [
        // 私信话题不显示链接分享和生成分享图
        if (!isPrivateMessage)
          PopupMenuItem(
            value: 'link',
            child: Row(
              children: [
                Icon(Icons.link, size: 20, color: theme.colorScheme.onSurface),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_shareLink),
              ],
            ),
          ),
        if (!isPrivateMessage)
          PopupMenuItem(
            value: 'image',
            child: Row(
              children: [
                Icon(Icons.image_outlined, size: 20, color: theme.colorScheme.onSurface),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_generateShareImage),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'export',
          child: Row(
            children: [
              Icon(Icons.download_outlined, size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_exportArticle),
            ],
          ),
        ),
      ],
    );
  }
}
