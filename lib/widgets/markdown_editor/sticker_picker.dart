import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/dialog_utils.dart';
import '../common/cached_image.dart';
import '../common/loading_spinner.dart';
import 'sticker_market_sheet.dart';
import '../../../../../l10n/s.dart';

/// 表情包选择器
///
/// 单个滚动列表展示所有已订阅分组（带文字标题），
/// 顶部图标 Tab 作为锚点快速跳转。
class StickerPicker extends ConsumerStatefulWidget {
  final ValueChanged<String> onStickerSelected;

  /// 底部额外 padding（用于给悬浮 Tab 留空间）
  final double bottomPadding;

  const StickerPicker({
    super.key,
    required this.onStickerSelected,
    this.bottomPadding = 0,
  });

  @override
  ConsumerState<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends ConsumerState<StickerPicker>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();
  final GlobalKey _contentAreaKey = GlobalKey();
  List<GlobalKey> _groupKeys = [];
  int _activeGroupIndex = 0;

  /// 面板打开时快照，避免实时刷新影响体验
  List<StickerItem>? _recentSnapshot;
  bool _isProgrammaticScroll = false;
  bool _scrollThrottled = false;

  // ==================== 长按预览 ====================
  OverlayEntry? _previewEntry;
  final _previewNotifier = ValueNotifier<_PreviewData?>(null);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _endPreview();
    _previewNotifier.dispose();
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  void _openMarket() {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const StickerMarketSheet(),
    );
  }

  void _onStickerTap(StickerItem sticker) {
    ref.read(recentStickersProvider.notifier).add(sticker);
    widget.onStickerSelected(sticker.toMarkdown());
  }

  // ==================== 滚动锚点 ====================

  void _onScroll() {
    if (_isProgrammaticScroll || _scrollThrottled) return;
    _scrollThrottled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scrollThrottled = false;
      if (mounted) _updateActiveGroup();
    });
  }

  void _updateActiveGroup() {
    if (_groupKeys.isEmpty) return;
    final contentBox =
        _contentAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null || !contentBox.attached) return;
    final contentTop = contentBox.localToGlobal(Offset.zero).dy;

    int activeIndex = 0;
    for (int i = 0; i < _groupKeys.length; i++) {
      final ctx = _groupKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box == null || box is! RenderBox || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= contentTop + 20) {
        activeIndex = i;
      }
    }
    if (_activeGroupIndex != activeIndex) {
      setState(() => _activeGroupIndex = activeIndex);
      _ensureTabVisible(activeIndex);
    }
  }

  Future<void> _scrollToGroup(int index) async {
    if (index < 0 || index >= _groupKeys.length) return;
    final ctx = _groupKeys[index].currentContext;
    if (ctx == null) return;
    _isProgrammaticScroll = true;
    setState(() => _activeGroupIndex = index);
    _ensureTabVisible(index);
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isProgrammaticScroll = false;
  }

  void _ensureTabVisible(int index) {
    if (!_tabScrollController.hasClients) return;
    const tabWidth = 40.0;
    final target = index * tabWidth -
        _tabScrollController.position.viewportDimension / 2 +
        tabWidth / 2;
    _tabScrollController.animateTo(
      target.clamp(0.0, _tabScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ==================== 长按预览 ====================

  void _startPreview(StickerItem sticker, Rect itemRect) {
    HapticFeedback.mediumImpact();
    final screenSize = MediaQuery.of(context).size;
    _previewNotifier.value = _PreviewData(sticker, itemRect, screenSize);
    _previewEntry = OverlayEntry(
      builder: (_) => _StickerPreviewOverlay(notifier: _previewNotifier),
    );
    Overlay.of(context).insert(_previewEntry!);
  }

  void _movePreview(Offset globalPosition) {
    final found = _findStickerAt(globalPosition);
    if (found != null && found.$1.id != _previewNotifier.value?.sticker.id) {
      HapticFeedback.selectionClick();
      final screenSize = _previewNotifier.value!.screenSize;
      _previewNotifier.value = _PreviewData(found.$1, found.$2, screenSize);
    }
  }

  void _endPreview() {
    _previewEntry?.remove();
    _previewEntry = null;
    _previewNotifier.value = null;
  }

  (StickerItem, Rect)? _findStickerAt(Offset globalPosition) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      if (entry.target is RenderMetaData) {
        final meta = entry.target as RenderMetaData;
        if (meta.metaData is StickerItem) {
          final rect = meta.localToGlobal(Offset.zero) & meta.size;
          return (meta.metaData as StickerItem, rect);
        }
      }
    }
    return null;
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final subscribedIds = ref.watch(subscribedStickerIdsProvider);
    _recentSnapshot ??= ref.read(recentStickersProvider);
    final recentStickers = _recentSnapshot!;
    final groupsAsync = ref.watch(stickerGroupsProvider);

    return ClipRect(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: (() {
          if (subscribedIds.isEmpty) return _buildEmptyState();
          final allGroups = groupsAsync.value;
          if (allGroups != null) {
            return _buildContent(
              _filterSubscribed(allGroups, subscribedIds),
              recentStickers,
            );
          }
          return groupsAsync.when(
            data: (groups) => _buildContent(
              _filterSubscribed(groups, subscribedIds),
              recentStickers,
            ),
            loading: () => const Center(child: LoadingSpinner()),
            error: (err, stack) => _buildError(),
          );
        })(),
      ),
    );
  }

  List<StickerGroup> _filterSubscribed(
    List<StickerGroup> allGroups,
    List<String> subscribedIds,
  ) {
    final groupMap = {for (final g in allGroups) g.id: g};
    return subscribedIds
        .where((id) => groupMap.containsKey(id))
        .map((id) => groupMap[id]!)
        .toList();
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sticky_note_2_outlined,
              size: 48,
              color: theme.colorScheme.outline.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(S.current.sticker_noStickers,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _openMarket,
            icon: const Icon(Icons.add, size: 18),
            label: Text(S.current.sticker_addFromMarket),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(S.current.sticker_loadFailed,
              style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.invalidate(stickerGroupsProvider),
            child: Text(S.current.common_retry),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    List<StickerGroup> groups,
    List<StickerItem> recentStickers,
  ) {
    if (groups.isEmpty) return _buildEmptyState();

    // 预加载所有已订阅分组的详情，避免滚动时逐个 loading
    for (final group in groups) {
      ref.read(stickerGroupDetailProvider(group.id));
    }

    final hasRecent = recentStickers.isNotEmpty;
    final totalGroups = (hasRecent ? 1 : 0) + groups.length;

    while (_groupKeys.length < totalGroups) {
      _groupKeys.add(GlobalKey());
    }
    if (_groupKeys.length > totalGroups) {
      _groupKeys = _groupKeys.sublist(0, totalGroups);
    }

    return Column(
      children: [
        _buildTabBar(groups, hasRecent),
        Expanded(
          key: _contentAreaKey,
          child: CustomScrollView(
            controller: _scrollController,
            scrollCacheExtent: ScrollCacheExtent.pixels(500),
            slivers: _buildSlivers(groups, hasRecent, recentStickers),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(List<StickerGroup> groups, bool hasRecent) {
    final theme = Theme.of(context);
    final totalTabs = (hasRecent ? 1 : 0) + groups.length;
    const tabSlotWidth = 40.0;
    const tabWidth = 36.0;
    const tabMargin = 2.0;
    final activeIndex = _activeGroupIndex.clamp(0, totalTabs - 1);

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 40,
            child: SingleChildScrollView(
              controller: _tabScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: totalTabs * tabSlotWidth,
                height: 40,
                child: Stack(
                  children: [
                    // 滑动指示器
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      left: activeIndex * tabSlotWidth + tabMargin,
                      top: 4,
                      bottom: 4,
                      width: tabWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    // Tab 图标
                    Row(
                      children: List.generate(totalTabs, (index) {
                        Widget icon;
                        if (hasRecent && index == 0) {
                          icon = Icon(
                            Icons.access_time,
                            size: 20,
                            color: activeIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          );
                        } else {
                          final group = groups[hasRecent ? index - 1 : index];
                          icon = _buildGroupTabIcon(group);
                        }
                        return GestureDetector(
                          onTap: () => _scrollToGroup(index),
                          child: SizedBox(
                            width: tabSlotWidth,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: tabMargin,
                                vertical: 4,
                              ),
                              child: Center(child: icon),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Container(
            height: 20, width: 1, color: theme.colorScheme.outlineVariant),
        IconButton(
          icon: Icon(Icons.add_circle_outline,
              size: 20, color: theme.colorScheme.primary),
          onPressed: _openMarket,
          tooltip: S.current.sticker_addTooltip,
        ),
      ],
    );
  }

  Widget _buildGroupTabIcon(StickerGroup group) {
    final icon = group.icon;
    if (icon.startsWith('http://') || icon.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedImage(
          url: icon,
          width: 24,
          height: 24,
          memCacheWidth: 48,
          memCacheHeight: 48,
          fit: BoxFit.cover,
          cacheManager: StickerCacheManager(),
          placeholder: (_) => _buildFallbackIcon(group.name),
          errorBuilder: (_, _, _) => _buildFallbackIcon(group.name),
        ),
      );
    }
    if (icon.isNotEmpty) {
      return Text(icon, style: const TextStyle(fontSize: 18));
    }
    return _buildFallbackIcon(group.name);
  }

  Widget _buildFallbackIcon(String name) {
    return Text(
      name.isNotEmpty ? name[0] : '?',
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  List<Widget> _buildSlivers(
    List<StickerGroup> groups,
    bool hasRecent,
    List<StickerItem> recentStickers,
  ) {
    final slivers = <Widget>[];
    int keyIndex = 0;

    if (hasRecent) {
      slivers.add(SliverToBoxAdapter(
        child: _buildSectionHeader(S.current.common_recentlyUsed, _groupKeys[keyIndex]),
      ));
      slivers.add(_buildStickerSliverGrid(recentStickers));
      keyIndex++;
    }

    for (final group in groups) {
      slivers.add(SliverToBoxAdapter(
        child: _buildSectionHeader(group.name, _groupKeys[keyIndex]),
      ));
      slivers.add(_StickerGroupSliverContent(
        groupId: group.id,
        onStickerTap: _onStickerTap,
        onPreviewStart: _startPreview,
        onPreviewMove: _movePreview,
        onPreviewEnd: _endPreview,
      ));
      keyIndex++;
    }

    // 底部留白
    if (widget.bottomPadding > 0) {
      slivers.add(SliverToBoxAdapter(
        child: SizedBox(height: widget.bottomPadding),
      ));
    }

    return slivers;
  }

  Widget _buildSectionHeader(String title, GlobalKey key) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildStickerSliverGrid(List<StickerItem> stickers) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => _StickerItemWidget(
            sticker: stickers[index],
            onTap: () => _onStickerTap(stickers[index]),
            onPreviewStart: _startPreview,
            onPreviewMove: _movePreview,
            onPreviewEnd: _endPreview,
          ),
          childCount: stickers.length,
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

/// 单个分组的 Sliver 内容（懒加载）
class _StickerGroupSliverContent extends ConsumerWidget {
  final String groupId;
  final ValueChanged<StickerItem> onStickerTap;
  final void Function(StickerItem, Rect) onPreviewStart;
  final void Function(Offset) onPreviewMove;
  final VoidCallback onPreviewEnd;

  const _StickerGroupSliverContent({
    required this.groupId,
    required this.onStickerTap,
    required this.onPreviewStart,
    required this.onPreviewMove,
    required this.onPreviewEnd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(stickerGroupDetailProvider(groupId));
    final theme = Theme.of(context);

    final detail = detailAsync.value;
    if (detail != null) return _buildGrid(detail);

    return detailAsync.when(
      data: _buildGrid,
      loading: () => const SliverToBoxAdapter(
        child: SizedBox(height: 80, child: Center(child: LoadingSpinner())),
      ),
      error: (err, stack) => SliverToBoxAdapter(
        child: SizedBox(
          height: 80,
          child: Center(
            child: TextButton(
              onPressed: () =>
                  ref.invalidate(stickerGroupDetailProvider(groupId)),
              child: Text(S.current.common_loadFailedTapRetry,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(StickerGroupDetail detail) {
    if (detail.emojis.isEmpty) {
      return SliverToBoxAdapter(
        child: SizedBox(height: 80, child: Center(child: Text(S.current.sticker_groupEmpty))),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => _StickerItemWidget(
            sticker: detail.emojis[index],
            onTap: () => onStickerTap(detail.emojis[index]),
            onPreviewStart: onPreviewStart,
            onPreviewMove: onPreviewMove,
            onPreviewEnd: onPreviewEnd,
          ),
          childCount: detail.emojis.length,
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

/// 单个表情包图片（支持长按滑动预览）
class _StickerItemWidget extends StatelessWidget {
  final StickerItem sticker;
  final VoidCallback onTap;
  final void Function(StickerItem, Rect) onPreviewStart;
  final void Function(Offset) onPreviewMove;
  final VoidCallback onPreviewEnd;

  const _StickerItemWidget({
    required this.sticker,
    required this.onTap,
    required this.onPreviewStart,
    required this.onPreviewMove,
    required this.onPreviewEnd,
  });

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: sticker,
      behavior: HitTestBehavior.opaque,
      child: GestureDetector(
        onTap: onTap,
        onLongPressStart: (_) {
          final box = context.findRenderObject() as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          onPreviewStart(sticker, rect);
        },
        onLongPressMoveUpdate: (details) {
          onPreviewMove(details.globalPosition);
        },
        onLongPressEnd: (_) => onPreviewEnd(),
        onLongPressCancel: onPreviewEnd,
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: CachedImage(
            url: sticker.url,
            fit: BoxFit.contain,
            memCacheWidth: 160,
            memCacheHeight: 160,
            cacheManager: StickerCacheManager(),
            errorBuilder: (_, _, _) => Icon(
              Icons.broken_image_outlined,
              size: 24,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}

/// 预览数据
class _PreviewData {
  final StickerItem sticker;
  final Rect itemRect;
  final Size screenSize;
  const _PreviewData(this.sticker, this.itemRect, this.screenSize);
}

/// 预览 Overlay（监听 ValueNotifier 实时更新）
class _StickerPreviewOverlay extends StatelessWidget {
  final ValueNotifier<_PreviewData?> notifier;
  const _StickerPreviewOverlay({required this.notifier});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_PreviewData?>(
      valueListenable: notifier,
      builder: (context, data, _) {
        if (data == null) return const SizedBox.shrink();
        return _StickerPreviewPopup(
          sticker: data.sticker,
          itemRect: data.itemRect,
          screenSize: data.screenSize,
        );
      },
    );
  }
}

/// 长按弹出的表情包放大预览
class _StickerPreviewPopup extends StatelessWidget {
  final StickerItem sticker;
  final Rect itemRect;
  final Size screenSize;

  static const double _previewSize = 180;
  static const double _nameHeight = 28;
  static const double _cardPadding = 8;
  static const double _totalHeight = _previewSize + _nameHeight + _cardPadding * 2;
  static const double _totalWidth = _previewSize + _cardPadding * 2;
  static const double _screenMargin = 12;

  const _StickerPreviewPopup({
    required this.sticker,
    required this.itemRect,
    required this.screenSize,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 垂直定位：优先上方，空间不足时改下方
    final spaceAbove = itemRect.top - _screenMargin;
    final showAbove = spaceAbove >= _totalHeight;
    final dy = showAbove
        ? itemRect.top - _totalHeight - 8
        : itemRect.bottom + 8;

    // 水平居中对齐缩略图，clamp 防溢出
    final dx = (itemRect.center.dx - _totalWidth / 2)
        .clamp(_screenMargin, screenSize.width - _totalWidth - _screenMargin);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      left: dx,
      top: dy,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Opacity(
            opacity: value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.6 + 0.4 * value,
              alignment: showAbove ? Alignment.bottomCenter : Alignment.topCenter,
              child: child,
            ),
          ),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            color: theme.colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(_cardPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: _previewSize,
                    height: _previewSize,
                    child: CachedImage(
                      url: sticker.url,
                      fit: BoxFit.contain,
                      // 不传 memCacheWidth → AVIF 完整解码（含动画）
                      cacheManager: StickerCacheManager(),
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _previewSize,
                    height: _nameHeight,
                    child: Center(
                      child: Text(
                        sticker.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
