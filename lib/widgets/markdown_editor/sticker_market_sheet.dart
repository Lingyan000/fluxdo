import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/error_utils.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/load_more_coordinator.dart';
import '../common/app_bottom_sheet.dart';
import '../common/error_view.dart';

import 'package:m3e_ui/m3e_ui.dart';

import '../common/paged_list_footer.dart';
import 'sticker_group_icon.dart';
import 'sticker_group_preview_sheet.dart';
import 'sticker_preview.dart';
import '../../../../../l10n/s.dart';

/// 表情包市场浏览面板 (Bottom Sheet)
///
/// 展示市场中所有可用的表情包分组，用户可以添加/移除。
/// 支持分页加载：首次只加载第一页，滚动到底部时自动加载下一页。
///
/// 外壳由 [AppBottomSheet.showDraggable] 提供：本面板带搜索框，必须走
/// `expandToFill` 那条分支（高度交给 DraggableScrollableSheet、不叠加键盘
/// 内边距），否则「固定高度 + viewInsets 顶起」会在键盘弹出时把标题栏和
/// 搜索框顶出屏幕。键盘内边距由列表自己加，与标签/分类选择面板同体例。
class StickerMarketSheet extends ConsumerStatefulWidget {
  /// 由 DraggableScrollableSheet 提供，必须交给列表才能联动拖拽缩放。
  final ScrollController scrollController;

  const StickerMarketSheet({super.key, required this.scrollController});

  @override
  ConsumerState<StickerMarketSheet> createState() => _StickerMarketSheetState();
}

class _StickerMarketSheetState extends ConsumerState<StickerMarketSheet> {
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator(
    triggerDistance: 600,
    releaseDistance: 600,
  );

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// 当前选中分类 id（'all' = 全部）；与 notifier 同步，驱动 chip 选中态
  String _selectedTopic = 'all';

  ScrollController get _scrollController => widget.scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    // controller 归 DraggableScrollableSheet 所有，只摘监听、不 dispose
    _scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final distance = pos.maxScrollExtent - pos.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(marketGroupsProvider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () => ref.read(marketGroupsProvider).value?.length ?? 0,
    );
  }

  Future<void> _retryLoadMore() async {
    _loadMoreCoordinator.resetCooldown();
    await ref.read(marketGroupsProvider.notifier).retryLoadMore();
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(marketGroupsProvider);
    final topicsAsync = ref.watch(marketTopicsProvider);

    return Column(
      children: [
        _buildSearchField(),
        _buildTopicChips(topicsAsync),
        Expanded(
          child: (() {
            final topicLabels = <String, String>{
              for (final topic
                  in topicsAsync.value ?? const <StickerMarketTopic>[])
                topic.id: topic.label,
            };
            final groups = groupsAsync.value;
            if (groups != null) {
              return _buildGroupList(groups, topicLabels);
            }
            return groupsAsync.when(
              data: (groups) => _buildGroupList(groups, topicLabels),
              loading: () => const Center(child: LoadingSpinner()),
              error: _buildError,
            );
          })(),
        ),
      ],
    );
  }

  // ==================== 搜索与分类 ====================

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      ref.read(marketGroupsProvider.notifier).setQuery(_searchController.text);
    });
  }

  void _selectTopic(String topicId) {
    if (topicId == _selectedTopic) return;
    setState(() => _selectedTopic = topicId);
    _searchDebounce?.cancel();
    _searchController.clear();
    ref.read(marketGroupsProvider.notifier).setTopic(topicId);
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: InputFieldShell(
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            return TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              onChanged: (_) => _scheduleSearch(),
              decoration: InputDecoration(
                isDense: true,
                hintText: S.current.sticker_marketSearchHint,
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: S.current.common_clear,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Symbols.close_rounded, size: 18),
                        onPressed: () {
                          _searchDebounce?.cancel();
                          _searchController.clear();
                          ref.read(marketGroupsProvider.notifier).setQuery('');
                        },
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 分类 chips（横向滚动）。topics.json 取不到（旧版服务端 / 请求失败）或
  /// 全部是空分类时整行不占位，此时只剩「全部」的浏览行为；totalGroups == 0
  /// 的空分类不展示（点了只会看到空列表）。
  Widget _buildTopicChips(AsyncValue<List<StickerMarketTopic>> topicsAsync) {
    final theme = Theme.of(context);
    final topics = (topicsAsync.value ?? const <StickerMarketTopic>[])
        .where((t) => t.totalGroups > 0)
        .toList(growable: false);
    if (topics.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: topics.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final topic = topics[index];
          final selected = topic.id == _selectedTopic;
          return ChoiceChip(
            label: Text(topic.label),
            selected: selected,
            onSelected: (_) => _selectTopic(topic.id),
            labelStyle: TextStyle(
              fontSize: 12,
              color: selected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            selectedColor: theme.colorScheme.primary,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            side: BorderSide(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          );
        },
      ),
    );
  }

  Widget _buildError(Object error, StackTrace stackTrace) {
    final theme = Theme.of(context);
    final errorInfo = ErrorUtils.getErrorInfo(error);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.error_rounded,
            size: 48,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            S.current.sticker_marketLoadFailed,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              errorInfo.message,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () {
                  _loadMoreCoordinator.resetCooldown();
                  ref.read(marketGroupsProvider.notifier).refresh();
                },
                child: Text(S.current.common_retry),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _showErrorDetails(error, stackTrace),
                child: Text(S.current.common_viewDetails),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showErrorDetails(Object error, StackTrace stackTrace) {
    final details = ErrorUtils.getErrorDetails(error, stackTrace);
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ErrorDetailsSheet(details: details),
    );
  }

  Widget _buildGroupList(
    List<StickerGroup> groups,
    Map<String, String> topicLabels,
  ) {
    if (groups.isEmpty) {
      final notifier = ref.read(marketGroupsProvider.notifier);
      return Center(
        child: Text(
          notifier.isSearchMode
              ? S.current.sticker_marketSearchEmpty
              : S.current.sticker_marketEmpty,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final notifier = ref.read(marketGroupsProvider.notifier);
    final itemCount = groups.length + 1;

    return ListView.builder(
      controller: _scrollController,
      // 外壳走 expandToFill、不叠加键盘内边距，键盘弹出时底部由列表自己让位
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      // 离屏只预 build 约半屏:每张卡片都会拉分组详情和 6 张缩略图,
      // 预建太多会把代理通道排满,点进预览页反而要等。
      scrollCacheExtent: ScrollCacheExtent.pixels(400),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= groups.length) {
          return PagedListFooter(
            hasMore: notifier.hasMore,
            isLoadingMore: notifier.isLoadingMore,
            isLoadMoreFailed: notifier.isLoadMoreFailed,
            onRetry: _retryLoadMore,
          );
        }
        final group = groups[index];
        return _StickerGroupCard(
          key: ValueKey(group.id),
          group: group,
          index: index,
          count: groups.length,
          topicLabel: topicLabels[group.topic],
        );
      },
    );
  }
}

/// 市场中的分组卡片:图标、名称、数量、添加按钮,下面一排预览。
///
/// 整个列表是一组分段卡片(按 index/count 决定圆角),跟随用户选的
/// 卡片样式。点卡片打开分组预览页。
///
/// 用 ConsumerWidget + `ref.watch(provider.select(...))` 让每张卡片只在
/// 自己 group.id 的订阅状态变化时 rebuild,其它 group 订阅状态变化不影响。
/// 配合 [RepaintBoundary],只重绘自身,不连累 list 其它 item。
class _StickerGroupCard extends ConsumerWidget {
  final StickerGroup group;
  final int index;
  final int count;
  final String? topicLabel;

  static const double _outerRadius = 16;
  static const double _innerRadius = 4;
  static const double _gap = 2;

  const _StickerGroupCard({
    super.key,
    required this.group,
    required this.index,
    required this.count,
    this.topicLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isSubscribed = ref.watch(
      subscribedStickerGroupsProvider.select(
        (groups) => groups.any((g) => g.id == group.id),
      ),
    );

    void onToggle() async {
      final notifier = ref.read(subscribedStickerGroupsProvider.notifier);
      if (isSubscribed) {
        await notifier.unsubscribe(group.id);
      } else {
        // 整个 group 一起交出去:name/icon 就地落盘，表情面板首帧不用再回网络
        await notifier.subscribe(group);
      }
    }

    final countText = S.current.sticker_emojiCount(group.emojiCount);
    final label = topicLabel;
    final subtitle = label == null || label.isEmpty
        ? countText
        : '$countText · $label';

    return RepaintBoundary(
      child: SegmentedCardItem(
        index: index,
        count: count,
        outerRadius: _outerRadius,
        innerRadius: _innerRadius,
        gap: _gap,
        color: PageBackgroundScope.isActive(context)
            ? Colors.transparent
            : null,
        child: InkWell(
          onTap: () {
            // 搜索框的键盘留在预览页后面会挡住底部按钮
            FocusManager.instance.primaryFocus?.unfocus();
            StickerGroupPreviewSheet.show(
              context,
              group,
              topicLabel: topicLabel,
            );
          },
          customBorder: RoundedSuperellipseBorder(
            borderRadius: SegmentedCardItem.borderRadiusOf(
              context,
              index: index,
              count: count,
              outerRadius: _outerRadius,
              innerRadius: _innerRadius,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // 图标高优先级:越过表情面板留在队列里的后台预取。
                    // 预览条是普通优先级,点进预览页时让位给预览页的格子。
                    StickerGroupIcon(
                      group: group,
                      priority: DownloadPriority.high,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    isSubscribed
                        ? FilledButton.tonalIcon(
                            onPressed: onToggle,
                            icon: const Icon(Symbols.check_rounded, size: 16),
                            label: Text(S.current.sticker_added),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: onToggle,
                            icon: const Icon(Symbols.add_rounded, size: 16),
                            label: Text(S.current.common_add),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                  ],
                ),
                const SizedBox(height: 10),
                _PreviewStrip(groupId: group.id),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 卡片里的预览条:分组前几张表情。
///
/// 卡片停留 [_armDelay] 后才开始拉取:快速滑过的卡片不排队,代理通道
/// 留给用户真正停下来看的内容。
class _PreviewStrip extends ConsumerStatefulWidget {
  const _PreviewStrip({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_PreviewStrip> createState() => _PreviewStripState();
}

class _PreviewStripState extends ConsumerState<_PreviewStrip> {
  static const double _spacing = 6;
  static const double _maxCell = 64;
  static const Duration _armDelay = Duration(milliseconds: 300);

  Timer? _armTimer;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _armTimer = Timer(_armDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _armed
        ? ref.watch(marketGroupPreviewProvider(widget.groupId)).value
        : null;
    final cellColor = Theme.of(context).colorScheme.surfaceContainer;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell =
            ((constraints.maxWidth - _spacing * (marketPreviewCount - 1)) /
                    marketPreviewCount)
                .clamp(0.0, _maxCell);
        return Row(
          children: [
            for (var i = 0; i < marketPreviewCount; i++) ...[
              if (i > 0) const SizedBox(width: _spacing),
              SizedBox.square(
                dimension: cell,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: cellColor,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(8),
                    ),
                  ),
                  child: items != null && i < items.length
                      ? Padding(
                          padding: const EdgeInsets.all(4),
                          child: StickerThumbnail(sticker: items[i]),
                        )
                      : null,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
