import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/sticker_thumbnail_provider.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/error_utils.dart';
import '../common/app_bottom_sheet.dart';
import '../common/cached_image.dart';
import '../common/error_view.dart';

import 'package:m3e_ui/m3e_ui.dart';

import 'sticker_market_sheet.dart';
import 'sticker_preview.dart';
import '../../../../../l10n/s.dart';

/// 表情包选择器
///
/// 单个滚动列表展示所有已订阅分组（带文字标题），
/// 顶部图标 Tab 作为锚点快速跳转。
class StickerPicker extends ConsumerStatefulWidget {
  final ValueChanged<String> onStickerSelected;

  /// 底部额外 padding（用于给悬浮 Tab 留空间）
  final double bottomPadding;

  /// 紧凑模式(桌面悬浮弹层):顶部圆角交给弹层壳,分类栏收紧
  final bool compact;

  /// 请求宿主收起面板(桌面悬浮弹层场景:打开表情包市场 sheet 前调用,
  /// sheet 走 Navigator 路由层,会被 root overlay 的弹层压住)
  final VoidCallback? onDismissRequested;

  const StickerPicker({
    super.key,
    required this.onStickerSelected,
    this.bottomPadding = 0,
    this.compact = false,
    this.onDismissRequested,
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

  /// 当前激活的 group index。**用 ValueNotifier 不用 setState** ——
  /// 滚动时这个值频繁变,如果走 setState 会 rebuild 整个 panel(含 30 张
  /// sticker grid),开销巨大。改成 notifier 后只让 40px 高的 TabBar
  /// 重绘,grid 不动 → 滚动丝滑。
  final ValueNotifier<int> _activeGroupIndex = ValueNotifier<int>(0);

  /// 面板打开时快照，避免实时刷新影响体验
  List<StickerItem>? _recentSnapshot;
  bool _isProgrammaticScroll = false;
  bool _scrollThrottled = false;
  bool _marketOpen = false;

  // ==================== 长按预览 ====================
  final _preview = StickerPreviewController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    stickerPanelOpened();
  }

  @override
  void dispose() {
    // 关键:让正在跑的 prefetch batch 立即作废,panel 关闭后不再继续
    // 后台解码新的缩略图。
    stickerPanelClosed();
    // 还要 cancel 所有 in-flight 单 URL thumbnail decode(用户点开 panel
    // 时可见 cell 触发的 _loadThumbnail 队列,即使 widget unmount,内部
    // future 仍在排队等解码)。bump generation → 所有 await 检查点 throw
    // _ThumbnailCancelled。
    // 打开市场前已取消旧一代任务；此时销毁不能再取消市场的新任务。
    if (!_marketOpen) StickerThumbnailProvider.cancelInflight();
    _preview.dispose();
    _activeGroupIndex.dispose();
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  Future<void> _openMarket() async {
    if (_marketOpen) return;
    setState(() => _marketOpen = true);
    stickerPanelClosed();
    StickerThumbnailProvider.cancelInflight();
    // 先创建市场路由并捕获主题，再收起可能销毁当前 State 的宿主弹层。
    final dismissPicker = widget.onDismissRequested;
    // 市场面板带搜索框,必须走可拖拽外壳(expandToFill):固定高度那条分支会
    // 叠加 viewInsets,键盘弹出时把标题栏与搜索框顶出屏幕。initialSize 沿用
    // 原先的 0.8,打开时观感不变。
    final market = AppBottomSheet.showDraggable(
      context: context,
      title: S.current.sticker_marketTitle,
      showTitleDivider: true,
      initialSize: 0.8,
      actions: [
        Builder(
          builder: (sheetContext) => TextButton(
            // 按钮属于市场路由，不能引用已随选择器销毁的 State.context。
            onPressed: () => Navigator.pop(sheetContext),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(S.current.common_done),
          ),
        ),
      ],
      bodyBuilder: (context, scrollController) =>
          StickerMarketSheet(scrollController: scrollController),
    );
    dismissPicker?.call();
    try {
      await market;
    } finally {
      if (mounted) {
        stickerPanelOpened();
        setState(() => _marketOpen = false);
      }
    }
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
    if (_activeGroupIndex.value != activeIndex) {
      _activeGroupIndex.value = activeIndex; // 只 notify TabBar,不 rebuild panel
      _ensureTabVisible(activeIndex);
    }
  }

  Future<void> _scrollToGroup(int index) async {
    if (index < 0 || index >= _groupKeys.length) return;
    final ctx = _groupKeys[index].currentContext;
    if (ctx == null) return;
    _isProgrammaticScroll = true;
    _activeGroupIndex.value = index;
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
    final tabWidth = widget.compact ? 34.0 : 40.0;
    final target =
        index * tabWidth -
        _tabScrollController.position.viewportDimension / 2 +
        tabWidth / 2;
    _tabScrollController.animateTo(
      target.clamp(0.0, _tabScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 市场位于前景时卸载下层图片监听，禁止继续构建/加载订阅网格。
    if (_marketOpen) return const SizedBox.expand();
    // 已订阅分组含 tab 栏所需的 name/icon,prefs 同步读 —— 首帧就能画,
    // 不再为了拿这几个字段去拉全市场 288 组的分页索引。
    final subscribedGroups = ref.watch(subscribedStickerGroupsProvider);
    _recentSnapshot ??= ref.read(recentStickersProvider);
    final recentStickers = _recentSnapshot!;

    return ClipRect(
      child: Container(
        decoration: ShapeDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedSuperellipseBorder(
            borderRadius: widget.compact
                ? null
                : BorderRadius.vertical(top: context.shapes.radius(16)),
          ),
        ),
        child: subscribedGroups.isEmpty
            ? _buildEmptyState()
            : _buildContent(subscribedGroups, recentStickers),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.sticky_note_2_rounded,
            size: 48,
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            S.current.sticker_noStickers,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _openMarket,
            icon: const Icon(Symbols.add_rounded, size: 18),
            label: Text(S.current.sticker_addFromMarket),
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
            // 500px ≈ 1 屏,滚动时 off-screen widget 来不及预 build,新 sticker
            // enter viewport 才开始 _loadThumbnail。1500px ≈ 3 屏,提前 build +
            // 提前进 worker pool 解码,滚动到时 widget tree 已 ready、图也好或在解。
            scrollCacheExtent: ScrollCacheExtent.pixels(1500),
            slivers: _buildSlivers(groups, hasRecent, recentStickers),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(List<StickerGroup> groups, bool hasRecent) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    final totalTabs = (hasRecent ? 1 : 0) + groups.length;
    final tabSlotWidth = compact ? 34.0 : 40.0;
    final tabWidth = compact ? 30.0 : 36.0;
    const tabMargin = 2.0;
    final barHeight = compact ? 36.0 : 40.0;

    // 只这一块订阅 _activeGroupIndex 变化,scroll 时只这小条重绘,
    // 不影响 grid 等 panel 其它部分。
    return RepaintBoundary(
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: barHeight,
              child: SingleChildScrollView(
                controller: _tabScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: totalTabs * tabSlotWidth,
                  height: barHeight,
                  child: Stack(
                    children: [
                      // 滑动指示器 — 跟随 activeIndex
                      ValueListenableBuilder<int>(
                        valueListenable: _activeGroupIndex,
                        builder: (_, raw, _) {
                          final activeIndex = raw.clamp(0, totalTabs - 1);
                          return AnimatedPositioned(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            left: activeIndex * tabSlotWidth + tabMargin,
                            top: 4,
                            bottom: 4,
                            width: tabWidth,
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                color: theme.colorScheme.primaryContainer
                                    .withValues(alpha: 0.5),
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: context.shapes.borderRadius(8),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      // Tab 图标 — 整体结构不依赖 activeIndex(各 icon 不变),
                      // icon 颜色变化用内部 ValueListenableBuilder 局部更新
                      Row(
                        children: List.generate(totalTabs, (index) {
                          Widget icon;
                          if (hasRecent && index == 0) {
                            icon = ValueListenableBuilder<int>(
                              valueListenable: _activeGroupIndex,
                              builder: (_, raw, _) {
                                final activeIndex = raw.clamp(0, totalTabs - 1);
                                return Icon(
                                  Symbols.access_time_rounded,
                                  size: 20,
                                  color: activeIndex == index
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                );
                              },
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
            height: 20,
            width: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          IconButton(
            icon: const Icon(Symbols.add_circle_rounded, size: 20),
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: _openMarket,
            tooltip: S.current.sticker_addTooltip,
          ),
        ],
      ),
    );
  }

  Widget _buildGroupTabIcon(StickerGroup group) {
    final icon = group.icon;
    if (icon.startsWith('http://') || icon.startsWith('https://')) {
      return ClipRSuperellipse(
        borderRadius: context.shapes.borderRadius(4),
        child: CachedImage(
          url: icon,
          width: 24,
          height: 24,
          memCacheWidth: 48,
          memCacheHeight: 48,
          thumbnailMode: true,
          fit: BoxFit.cover,
          bucket: BlobImageCache.stickerOriginalBucket,
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
    // characters.first:名字以 🍟 等增补平面 emoji 开头时 name[0] 会切开代理对
    return Text(
      name.isNotEmpty ? name.characters.first : '?',
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
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
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            S.current.common_recentlyUsed,
            _groupKeys[keyIndex],
          ),
        ),
      );
      slivers.add(_buildStickerSliverGrid(recentStickers));
      keyIndex++;
    }

    for (final group in groups) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(group.name, _groupKeys[keyIndex]),
        ),
      );
      slivers.add(
        _StickerGroupSliverContent(
          groupId: group.id,
          onStickerTap: _onStickerTap,
          preview: _preview,
        ),
      );
      keyIndex++;
    }

    // 底部留白
    if (widget.bottomPadding > 0) {
      slivers.add(
        SliverToBoxAdapter(child: SizedBox(height: widget.bottomPadding)),
      );
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
          fontWeight: FontWeight.w500,
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
          (_, index) => StickerGridCell(
            sticker: stickers[index],
            preview: _preview,
            onTap: () => _onStickerTap(stickers[index]),
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
  final StickerPreviewController preview;

  const _StickerGroupSliverContent({
    required this.groupId,
    required this.onStickerTap,
    required this.preview,
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () =>
                      ref.invalidate(stickerGroupDetailProvider(groupId)),
                  child: Text(
                    S.current.common_loadFailedTapRetry,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Symbols.info_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: S.current.common_viewDetails,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final details = ErrorUtils.getErrorDetails(err, stack);
                    showAppBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) => ErrorDetailsSheet(details: details),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(StickerGroupDetail detail) {
    if (detail.emojis.isEmpty) {
      return SliverToBoxAdapter(
        child: SizedBox(
          height: 80,
          child: Center(child: Text(S.current.sticker_groupEmpty)),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => StickerGridCell(
            sticker: detail.emojis[index],
            preview: preview,
            onTap: () => onStickerTap(detail.emojis[index]),
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
