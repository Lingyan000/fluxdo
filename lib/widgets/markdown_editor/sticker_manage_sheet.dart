import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../common/app_bottom_sheet.dart';
import 'sticker_group_icon.dart';
import 'sticker_group_preview_sheet.dart';

/// 「我的表情包」:已添加分组的排序与移除。
///
/// 拖动把手(或长按整行)调整顺序,表情面板按此顺序显示;点一行打开
/// 分组预览页。
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
    final groups = ref.watch(subscribedStickerGroupsProvider);
    final notifier = ref.read(subscribedStickerGroupsProvider.notifier);

    if (groups.isEmpty) {
      return Center(
        child: Text(
          S.current.sticker_noStickers,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ReorderableListView.builder(
      scrollController: scrollController,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      header: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text(
          S.current.sticker_manageReorderHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      itemCount: groups.length,
      onReorderItem: notifier.reorder,
      proxyDecorator: (child, index, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Material(
          type: MaterialType.transparency,
          elevation: 6 * Curves.easeOut.transform(animation.value),
          child: child,
        ),
        child: child,
      ),
      itemBuilder: (context, index) {
        final group = groups[index];
        return _ManageRow(
          key: ValueKey(group.id),
          group: group,
          index: index,
          count: groups.length,
          onRemove: () => notifier.unsubscribe(group.id),
        );
      },
    );
  }
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({
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
          leading: StickerGroupIcon(group: group),
          title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            S.current.sticker_emojiCount(group.emojiCount),
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => StickerGroupPreviewSheet.show(context, group),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: S.current.common_remove,
                icon: const Icon(Symbols.remove_circle_rounded),
                color: theme.colorScheme.error,
                onPressed: onRemove,
              ),
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
