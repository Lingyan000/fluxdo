import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticker.dart';
import '../../providers/sticker_favorites_provider.dart';
import '../../providers/sticker_provider.dart';
import '../../services/sticker_favorites_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/sticker_thumbnail_provider.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/error_utils.dart';
import '../common/app_bottom_sheet.dart';
import '../common/cached_image.dart';
import '../common/error_view.dart';

import 'package:m3e_ui/m3e_ui.dart';

import 'sticker_favorite_ui.dart';
import 'sticker_group_preview_sheet.dart';
import 'sticker_manage_sheet.dart';
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
  final GlobalKey _tabStripKey = GlobalKey();
  Timer? _tabAutoScrollTimer;
  int _tabAutoScrollDirection = 0;

  /// 本次打开面板期间发送过表情的分组(最近的在后)。开启动态排序时,
  /// 面板关闭才把它们移到最前:打开期间 tab 不跳动。
  final _usedGroupIds = <String>[];
  SubscribedStickerGroupsNotifier? _groupsNotifier;
  bool _dynamicOrder = false;
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
  bool _sheetOpen = false;

  // ==================== 长按预览 ====================
  late final _preview = StickerPreviewController(
    actionsBuilder: _previewActions,
  );

  /// 「最近使用」分区里格子的来源标记(菜单据此提供「从最近使用中删除」)。
  static const _recentOrigin = #recent;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    stickerPanelOpened();
    _groupsNotifier = ref.read(subscribedStickerGroupsProvider.notifier);
    _dynamicOrder = ref.read(stickerDynamicOrderProvider);
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
    if (!_sheetOpen) StickerThumbnailProvider.cancelInflight();
    _stopTabAutoScroll();
    if (_dynamicOrder && _usedGroupIds.isNotEmpty) {
      // dispose 期间不能再用 ref,notifier 在 initState 时取好
      unawaited(
        _groupsNotifier?.moveToFrontAll(_usedGroupIds.reversed.toList()),
      );
    }
    _preview.dispose();
    _activeGroupIndex.dispose();
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  /// 在面板之上打开一个弹层(市场、分组预览等)。
  ///
  /// 弹层在前景期间卸载下层网格的图片监听并取消面板的预取与解码,关闭后
  /// 恢复;桌面悬浮弹层场景先收起面板(弹层走 Navigator 路由层,会被
  /// root overlay 的悬浮面板压住)。
  Future<void> _openForegroundSheet(
    Future<void> Function(BuildContext context) show,
  ) async {
    if (_sheetOpen) return;
    setState(() => _sheetOpen = true);
    stickerPanelClosed();
    StickerThumbnailProvider.cancelInflight();
    // 先创建弹层路由并捕获主题，再收起可能销毁当前 State 的宿主弹层。
    final dismissPicker = widget.onDismissRequested;
    final sheet = show(context);
    dismissPicker?.call();
    try {
      await sheet;
    } finally {
      if (mounted) {
        stickerPanelOpened();
        setState(() => _sheetOpen = false);
      }
    }
  }

  Future<void> _openMarket() => _openForegroundSheet(
    // 市场面板带搜索框,必须走可拖拽外壳(expandToFill):固定高度那条分支会
    // 叠加 viewInsets,键盘弹出时把标题栏与搜索框顶出屏幕。initialSize 沿用
    // 原先的 0.8,打开时观感不变。
    (context) => AppBottomSheet.showDraggable(
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
    ),
  );

  /// 打开表情所属分组的预览页。已订阅的分组直接用本地元信息,
  /// 否则从市场概要里找(找不到就用占位,标题为空但内容照常加载)。
  Future<void> _openGroupPreview(String groupId) async {
    var group = ref
        .read(subscribedStickerGroupsProvider)
        .where((g) => g.id == groupId)
        .firstOrNull;
    if (group == null) {
      try {
        final all = await ref.read(stickerMarketServiceProvider).getAllGroups();
        group = all.where((g) => g.id == groupId).firstOrNull;
      } catch (_) {
        // 概要取不到不影响打开预览页
      }
    }
    if (!mounted) return;
    final target =
        group ??
        StickerGroup(
          id: groupId,
          name: '',
          icon: '',
          order: 0,
          emojiCount: 0,
          isArchived: false,
        );
    await _openForegroundSheet(
      (context) => StickerGroupPreviewSheet.show(context, target),
    );
  }

  List<StickerPreviewAction> _previewActions(StickerPreviewTarget target) {
    final sticker = target.sticker;
    final favorites = ref.read(stickerFavoritesProvider.notifier);
    final favoriteCategory = favorites.categoryOf(sticker.url);
    final hasOtherCategories = ref
        .read(stickerFavoritesProvider)
        .any((c) => c.id != favoriteCategory && !c.isDefault);
    return [
      StickerPreviewAction(
        icon: Symbols.send_rounded,
        label: S.current.common_send,
        onSelected: () => _onStickerTap(sticker),
      ),
      if (favoriteCategory == null)
        StickerPreviewAction(
          icon: Symbols.star_rounded,
          label: S.current.sticker_favoriteAction,
          onSelected: () => _favorite(sticker),
        )
      else ...[
        if (hasOtherCategories ||
            favoriteCategory != StickerFavoriteCategory.defaultId)
          StickerPreviewAction(
            icon: Symbols.drive_file_move_rounded,
            label: S.current.sticker_favoriteMove,
            onSelected: () => _openForegroundSheet(
              (context) => showFavoriteCategoryPicker(context, sticker),
            ),
          ),
        StickerPreviewAction(
          icon: Symbols.star_rounded,
          label: S.current.sticker_unfavorite,
          destructive: true,
          onSelected: () => favorites.remove({sticker.url}),
        ),
      ],
      if (sticker.groupId.isNotEmpty)
        StickerPreviewAction(
          icon: Symbols.photo_library_rounded,
          label: S.current.sticker_viewGroup,
          onSelected: () => _openGroupPreview(sticker.groupId),
        ),
      if (target.origin == _recentOrigin)
        StickerPreviewAction(
          icon: Symbols.delete_rounded,
          label: S.current.sticker_removeFromRecent,
          destructive: true,
          onSelected: () => _removeRecent(sticker),
        ),
    ];
  }

  /// 收藏:没有自定义分类时直接收进默认分类,否则弹出分类选择
  /// (选择弹层要走前景弹层流程,桌面悬浮面板会压住路由层)。
  void _favorite(StickerItem sticker) {
    final hasCustom = ref
        .read(stickerFavoritesProvider)
        .any((c) => !c.isDefault);
    if (hasCustom) {
      _openForegroundSheet(
        (context) => showFavoriteCategoryPicker(context, sticker),
      );
    } else {
      favoriteSticker(context, sticker);
    }
  }

  void _removeRecent(StickerItem sticker) {
    ref.read(recentStickersProvider.notifier).remove(sticker.id);
    // 面板用打开时的快照,这里手动同步,删除立即生效
    setState(() {
      _recentSnapshot = [
        for (final s in _recentSnapshot ?? const <StickerItem>[])
          if (s.id != sticker.id) s,
      ];
    });
  }

  void _onStickerTap(StickerItem sticker) {
    ref.read(recentStickersProvider.notifier).add(sticker);
    if (sticker.groupId.isNotEmpty) {
      _usedGroupIds
        ..remove(sticker.groupId)
        ..add(sticker.groupId);
    }
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
    if (_sheetOpen) return const SizedBox.expand();
    // 已订阅分组含 tab 栏所需的 name/icon,prefs 同步读 —— 首帧就能画,
    // 不再为了拿这几个字段去拉全市场 288 组的分页索引。
    final subscribedGroups = ref.watch(subscribedStickerGroupsProvider);
    // 收藏实时跟随(收藏/移出立即可见);空分类不占面板位置
    final favorites = ref
        .watch(stickerFavoritesProvider)
        .where((c) => c.items.isNotEmpty)
        .toList(growable: false);
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
        child: subscribedGroups.isEmpty && favorites.isEmpty
            ? _buildEmptyState()
            : _buildContent(subscribedGroups, recentStickers, favorites),
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
    List<StickerFavoriteCategory> favorites,
  ) {
    // 预加载所有已订阅分组的详情，避免滚动时逐个 loading
    for (final group in groups) {
      ref.read(stickerGroupDetailProvider(group.id));
    }

    final hasRecent = recentStickers.isNotEmpty;
    // 分区顺序:最近使用 → 收藏分类 → 已订阅分组;tab 与分区一一对应
    final totalGroups = (hasRecent ? 1 : 0) + favorites.length + groups.length;

    while (_groupKeys.length < totalGroups) {
      _groupKeys.add(GlobalKey());
    }
    if (_groupKeys.length > totalGroups) {
      _groupKeys = _groupKeys.sublist(0, totalGroups);
    }

    return Column(
      children: [
        _buildTabBar(groups, hasRecent, favorites),
        Expanded(
          key: _contentAreaKey,
          child: CustomScrollView(
            controller: _scrollController,
            // 500px ≈ 1 屏,滚动时 off-screen widget 来不及预 build,新 sticker
            // enter viewport 才开始 _loadThumbnail。1500px ≈ 3 屏,提前 build +
            // 提前进 worker pool 解码,滚动到时 widget tree 已 ready、图也好或在解。
            scrollCacheExtent: ScrollCacheExtent.pixels(1500),
            slivers: _buildSlivers(
              groups,
              hasRecent,
              recentStickers,
              favorites,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(
    List<StickerGroup> groups,
    bool hasRecent,
    List<StickerFavoriteCategory> favorites,
  ) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    // 排在分组前面的固定分区数(最近使用 + 收藏分类),它们不参与拖拽排序
    final leading = (hasRecent ? 1 : 0) + favorites.length;
    final totalTabs = leading + groups.length;
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
              key: _tabStripKey,
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
                          } else if (index < leading) {
                            icon = _buildFavoriteTabIcon(
                              favorites[index - (hasRecent ? 1 : 0)],
                              index,
                              totalTabs,
                            );
                          } else {
                            icon = _buildGroupTabIcon(groups[index - leading]);
                          }
                          final tab = GestureDetector(
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
                          if (index < leading) return tab;
                          return _buildDraggableTab(
                            groupIndex: index - leading,
                            tab: tab,
                            icon: icon,
                            slotWidth: tabSlotWidth,
                            height: barHeight,
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
            icon: const Icon(Symbols.tune_rounded, size: 20),
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: () => _openForegroundSheet(StickerManageSheet.show),
            tooltip: S.current.sticker_manageTooltip,
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

  /// 分组 tab:长按拖到别的 tab 上调整顺序,拖到 tab 栏两端时自动滚动。
  Widget _buildDraggableTab({
    required int groupIndex,
    required Widget tab,
    required Widget icon,
    required double slotWidth,
    required double height,
  }) {
    final theme = Theme.of(context);
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != groupIndex,
      onAcceptWithDetails: (details) {
        // 落在目标 tab 上 = 占据它的位置
        ref
            .read(subscribedStickerGroupsProvider.notifier)
            .reorder(details.data, groupIndex);
        HapticFeedback.selectionClick();
      },
      builder: (context, candidates, _) => LongPressDraggable<int>(
        data: groupIndex,
        axis: Axis.horizontal,
        hapticFeedbackOnStart: true,
        onDragUpdate: (details) => _autoScrollTabs(details.globalPosition),
        onDragEnd: (_) => _stopTabAutoScroll(),
        onDraggableCanceled: (_, _) => _stopTabAutoScroll(),
        feedback: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: slotWidth,
            height: height,
            child: Center(child: Transform.scale(scale: 1.25, child: icon)),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: tab),
        child: candidates.isEmpty
            ? tab
            : DecoratedBox(
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(8),
                    side: BorderSide(color: theme.colorScheme.primary),
                  ),
                ),
                child: tab,
              ),
      ),
    );
  }

  /// 拖拽中指针靠近 tab 栏两端时持续滚动,离开即停。
  void _autoScrollTabs(Offset globalPosition) {
    final box = _tabStripKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !_tabScrollController.hasClients) {
      return;
    }
    const edge = 36.0;
    final x = box.globalToLocal(globalPosition).dx;
    final direction = x < edge
        ? -1
        : x > box.size.width - edge
        ? 1
        : 0;
    if (direction == _tabAutoScrollDirection) return;
    _stopTabAutoScroll();
    if (direction == 0) return;
    _tabAutoScrollDirection = direction;
    _tabAutoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (
      _,
    ) {
      if (!_tabScrollController.hasClients) return;
      final position = _tabScrollController.position;
      position.jumpTo(
        (position.pixels + direction * 6).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _stopTabAutoScroll() {
    _tabAutoScrollTimer?.cancel();
    _tabAutoScrollTimer = null;
    _tabAutoScrollDirection = 0;
  }

  /// 收藏分类的 tab 图标:默认分类是星标(选中时着色,与「最近使用」一致),
  /// 自定义分类用第一张表情。
  Widget _buildFavoriteTabIcon(
    StickerFavoriteCategory category,
    int index,
    int totalTabs,
  ) {
    if (category.isDefault) {
      final theme = Theme.of(context);
      return ValueListenableBuilder<int>(
        valueListenable: _activeGroupIndex,
        builder: (_, raw, _) => Icon(
          Symbols.star_rounded,
          size: 20,
          fill: 1,
          color: raw.clamp(0, totalTabs - 1) == index
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return SizedBox.square(
      dimension: 24,
      child: StickerThumbnail(sticker: category.items.first),
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
    List<StickerFavoriteCategory> favorites,
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
      slivers.add(_buildStickerSliverGrid(recentStickers, _recentOrigin));
      keyIndex++;
    }

    for (final category in favorites) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            stickerFavoriteCategoryLabel(category),
            _groupKeys[keyIndex],
          ),
        ),
      );
      slivers.add(
        _buildStickerSliverGrid(category.items, _FavoriteOrigin(category.id)),
      );
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

  Widget _buildStickerSliverGrid(List<StickerItem> stickers, Object origin) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => StickerGridCell(
            sticker: stickers[index],
            preview: _preview,
            origin: origin,
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

/// 收藏分区里格子的来源标记。
class _FavoriteOrigin {
  const _FavoriteOrigin(this.categoryId);
  final String categoryId;

  @override
  bool operator ==(Object other) =>
      other is _FavoriteOrigin && other.categoryId == categoryId;

  @override
  int get hashCode => categoryId.hashCode;
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
