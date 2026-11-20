import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../providers/sticker_favorites_provider.dart';
import '../../providers/sticker_provider.dart';
import '../../services/sticker_favorites_service.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';
import 'sticker_favorite_category_sheet.dart';
import 'sticker_favorite_ui.dart';
import 'sticker_group_icon.dart';
import 'sticker_group_preview_sheet.dart';
import 'sticker_preview.dart';

/// 「我的表情包」:收藏分类与已添加分组的管理。
///
/// 两段可拖拽排序的列表(拖动把手或长按整行),表情面板按此顺序显示:
/// - 收藏分类:新建、重命名、删除,点一行进分类详情;
/// - 已添加的表情包:移除,点一行打开分组预览页。
class StickerManageSheet extends ConsumerWidget {
  const StickerManageSheet({super.key, required this.scrollController});

  final ScrollController scrollController;

  static Future<void> show(BuildContext context) {
    return AppBottomSheet.showDraggable(
      context: context,
      title: S.current.sticker_manageTitle,
      showTitleDivider: true,
      initialSize: 0.7,
      bodyBuilder: (context, scrollController) =>
          StickerManageSheet(scrollController: scrollController),
    );
  }

  static const double _outerRadius = 16;
  static const double _innerRadius = 4;
  static const double _gap = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final categories = ref.watch(stickerFavoritesProvider);
    final favorites = ref.read(stickerFavoritesProvider.notifier);
    final groups = ref.watch(subscribedStickerGroupsProvider);
    final groupsNotifier = ref.read(subscribedStickerGroupsProvider.notifier);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(
              title: S.current.sticker_favoriteCategories,
              action: TextButton.icon(
                onPressed: () async {
                  final name = await showStickerCategoryNameDialog(
                    context,
                    title: S.current.sticker_newCategory,
                  );
                  if (name != null) await favorites.createCategory(name);
                },
                icon: const Icon(Symbols.add_rounded, size: 18),
                label: Text(S.current.sticker_newCategory),
              ),
            ),
          ),
        ),
        if (categories.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(S.current.sticker_favoriteEmpty, style: hintStyle),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverReorderableList(
              itemCount: categories.length,
              onReorderItem: favorites.reorderCategories,
              proxyDecorator: _proxyDecorator,
              itemBuilder: (context, index) {
                final category = categories[index];
                return _CategoryRow(
                  key: ValueKey('category-${category.id}'),
                  category: category,
                  index: index,
                  count: categories.length,
                );
              },
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(
              title: S.current.sticker_subscribedGroups,
              subtitle: S.current.sticker_manageReorderHint,
            ),
          ),
        ),
        if (groups.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(S.current.sticker_noStickers, style: hintStyle),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            sliver: SliverReorderableList(
              itemCount: groups.length,
              onReorderItem: groupsNotifier.reorder,
              proxyDecorator: _proxyDecorator,
              itemBuilder: (context, index) {
                final group = groups[index];
                return _GroupRow(
                  key: ValueKey('group-${group.id}'),
                  group: group,
                  index: index,
                  count: groups.length,
                  onRemove: () => groupsNotifier.unsubscribe(group.id),
                );
              },
            ),
          ),
      ],
    );
  }

  static Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) => Material(
      type: MaterialType.transparency,
      elevation: 6 * Curves.easeOut.transform(animation.value),
      child: child,
    ),
    child: child,
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle, this.action});

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 可拖拽排序的一行:分段卡片 + 长按整行拖动 + 尾部把手。
class _ReorderableRow extends StatelessWidget {
  const _ReorderableRow({
    required this.index,
    required this.count,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.trailing,
  });

  final int index;
  final int count;
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SegmentedCardItem(
      index: index,
      count: count,
      outerRadius: StickerManageSheet._outerRadius,
      innerRadius: StickerManageSheet._innerRadius,
      gap: StickerManageSheet._gap,
      child: ReorderableDelayedDragStartListener(
        index: index,
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          leading: leading,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: onTap,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              trailing,
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Symbols.drag_indicator_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryRow extends ConsumerWidget {
  const _CategoryRow({
    super.key,
    required this.category,
    required this.index,
    required this.count,
  });

  final StickerFavoriteCategory category;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(stickerFavoritesProvider.notifier);
    final label = stickerFavoriteCategoryLabel(category);

    Future<void> rename() async {
      final name = await showStickerCategoryNameDialog(
        context,
        title: S.current.sticker_renameCategory,
        initial: category.name,
      );
      if (name != null) await notifier.renameCategory(category.id, name);
    }

    Future<void> delete() async {
      if (category.items.isNotEmpty) {
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            content: Text(
              S.current.sticker_deleteCategoryConfirm(
                label,
                category.items.length,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(S.current.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(S.current.common_delete),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      await notifier.deleteCategory(category.id);
    }

    return _ReorderableRow(
      index: index,
      count: count,
      leading: SizedBox.square(
        dimension: StickerGroupIcon.size,
        child: category.isDefault || category.items.isEmpty
            ? Icon(
                category.isDefault
                    ? Symbols.star_rounded
                    : Symbols.folder_rounded,
                fill: category.isDefault ? 1 : 0,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : StickerThumbnail(sticker: category.items.first),
      ),
      title: label,
      subtitle: S.current.sticker_emojiCount(category.items.length),
      onTap: () => StickerFavoriteCategorySheet.show(context, category.id),
      trailing: SwipeDismissiblePopupMenuButton<VoidCallback>(
        icon: const Icon(Symbols.more_vert_rounded),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          if (!category.isDefault)
            PopupMenuItem(
              value: rename,
              child: Text(S.current.sticker_renameCategory),
            ),
          PopupMenuItem(
            value: delete,
            child: Text(
              S.current.sticker_deleteCategory,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    super.key,
    required this.group,
    required this.index,
    required this.count,
    required this.onRemove,
  });

  final StickerGroup group;
  final int index;
  final int count;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return _ReorderableRow(
      index: index,
      count: count,
      leading: StickerGroupIcon(group: group),
      title: group.name,
      subtitle: S.current.sticker_emojiCount(group.emojiCount),
      onTap: () => StickerGroupPreviewSheet.show(context, group),
      trailing: IconButton(
        tooltip: S.current.common_remove,
        icon: const Icon(Symbols.remove_circle_rounded),
        color: Theme.of(context).colorScheme.error,
        onPressed: onRemove,
      ),
    );
  }
}
