import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../../l10n/s.dart';
import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/app_bottom_sheet.dart';
import '../common/error_view.dart';
import 'sticker_group_icon.dart';
import 'sticker_preview.dart';

/// 表情包分组预览:添加前先看到分组里的全部表情。
///
/// 点按或长按表情放大预览;底部按钮添加或移除整个分组。
class StickerGroupPreviewSheet extends ConsumerStatefulWidget {
  const StickerGroupPreviewSheet({
    super.key,
    required this.group,
    required this.scrollController,
    this.topicLabel,
  });

  final StickerGroup group;
  final ScrollController scrollController;

  /// 分组所属市场分类的显示名(可选,显示在概要行)。
  final String? topicLabel;

  static Future<void> show(
    BuildContext context,
    StickerGroup group, {
    String? topicLabel,
  }) {
    return AppBottomSheet.showDraggable(
      context: context,
      title: group.name,
      initialSize: 0.75,
      footer: _SubscribeButton(group: group),
      bodyBuilder: (context, scrollController) => StickerGroupPreviewSheet(
        group: group,
        scrollController: scrollController,
        topicLabel: topicLabel,
      ),
    );
  }

  @override
  ConsumerState<StickerGroupPreviewSheet> createState() =>
      _StickerGroupPreviewSheetState();
}

class _StickerGroupPreviewSheetState
    extends ConsumerState<StickerGroupPreviewSheet> {
  final _preview = StickerPreviewController();

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(marketGroupDetailProvider(widget.group.id));
    final emojis = detailAsync.value?.emojis;

    return CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        SliverToBoxAdapter(child: _buildSummary(context, emojis?.length)),
        if (emojis != null)
          _buildGrid(emojis)
        else if (detailAsync.hasError)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView(
              error: detailAsync.error!,
              stackTrace: detailAsync.stackTrace,
              onRetry: () =>
                  ref.invalidate(marketGroupDetailProvider(widget.group.id)),
            ),
          )
        else
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: LoadingSpinner()),
          ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context, int? loadedCount) {
    final theme = Theme.of(context);
    final count = S.current.sticker_emojiCount(
      loadedCount ?? widget.group.emojiCount,
    );
    final topic = widget.topicLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          StickerGroupIcon(group: widget.group),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              topic == null || topic.isEmpty ? count : '$count · $topic',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<StickerItem> emojis) {
    if (emojis.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: Text(S.current.sticker_groupEmpty)),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => StickerGridCell(
            sticker: emojis[index],
            preview: _preview,
            priority: DownloadPriority.high,
          ),
          childCount: emojis.length,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 80,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
      ),
    );
  }
}

/// 预览页底部的添加/移除按钮(随订阅状态切换)。
class _SubscribeButton extends ConsumerWidget {
  const _SubscribeButton({required this.group});

  final StickerGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSubscribed = ref.watch(
      subscribedStickerGroupsProvider.select(
        (groups) => groups.any((g) => g.id == group.id),
      ),
    );
    final count =
        ref.watch(marketGroupDetailProvider(group.id)).value?.emojis.length ??
        group.emojiCount;
    final notifier = ref.read(subscribedStickerGroupsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: isSubscribed
          ? OutlinedButton.icon(
              onPressed: () => notifier.unsubscribe(group.id),
              icon: const Icon(Symbols.remove_rounded, size: 18),
              label: Text(S.current.sticker_removeGroup),
            )
          : FilledButton.icon(
              onPressed: () => notifier.subscribe(group),
              icon: const Icon(Symbols.add_rounded, size: 18),
              label: Text(S.current.sticker_addGroupCount(count)),
            ),
    );
  }
}
