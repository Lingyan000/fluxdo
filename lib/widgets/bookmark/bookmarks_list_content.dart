import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import '../../models/topic_card_style.dart';
import '../../pages/bookmarks/bookmarks_models.dart';
import '../../providers/category_provider.dart';
import '../../providers/preferences_provider.dart';
import '../topic/topic_card_layout.dart';
import '../topic/painted_topic_card.dart';
import '../../utils/blocked_user_filter.dart';
import '../../utils/platform_utils.dart';
import '../../utils/time_utils.dart';
import 'bookmark_preview_quick_editor.dart';
import '../common/error_view.dart';
import '../common/icon_glyph_span.dart';
import '../common/paged_list_footer.dart';
import '../desktop_refresh_indicator.dart';
import '../../utils/responsive.dart';
import '../topic/topic_list_skeleton.dart';
import '../topic/topic_item_builder.dart';
import '../topic/topic_preview_dialog.dart';

class BookmarksListContent extends ConsumerWidget {
  const BookmarksListContent({
    super.key,
    required this.bookmarksAsync,
    required this.bookmarkNameSuggestions,
    required this.bookmarkNameSuggestionsLoader,
    required this.scrollController,
    required this.onRefresh,
    required this.onTap,
    required this.onMiddleClick,
    required this.enableLongPress,
    required this.showSummaryBar,
    required this.selectedBookmarkName,
    required this.onSelectedBookmarkName,
    required this.hasMore,
    required this.isLoadMoreFailed,
    required this.isLoadingMore,
    required this.onRetryLoadMore,
    required this.onEditBookmark,
    required this.onQuickRenameBookmark,
    required this.onClearReminder,
    required this.onDeleteBookmark,
  });

  final AsyncValue<List<Topic>> bookmarksAsync;
  final List<String> bookmarkNameSuggestions;
  final Future<List<String>> Function() bookmarkNameSuggestionsLoader;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final ValueChanged<Topic> onTap;
  final ValueChanged<Topic> onMiddleClick;
  final bool enableLongPress;
  final bool showSummaryBar;
  final String? selectedBookmarkName;
  final ValueChanged<String?> onSelectedBookmarkName;
  final bool hasMore;
  final bool isLoadMoreFailed;
  final bool isLoadingMore;
  final VoidCallback onRetryLoadMore;
  final Future<void> Function(Topic topic) onEditBookmark;
  final Future<bool> Function(Topic topic, String? name) onQuickRenameBookmark;
  final Future<void> Function(Topic topic) onClearReminder;
  final Future<void> Function(Topic topic) onDeleteBookmark;

  // ── 长列表线性税的记忆化(本页单实例,static 安全)──────────────
  //
  // 此前每次 rebuild 都全量重跑三趟 O(N):屏蔽过滤 → 名称汇总 → 名称
  // 筛选;滚动中分页落地一次就是一次页面重建,列表越长线性税越重。
  // 全部以"输入 identity + 键值"判缓存,数据换代(新 list 实例)自动
  // 重算,零语义变化。
  static List<Topic>? _visibleSrc;
  static Set<String>? _visibleBlockedRef;
  static List<Topic>? _visibleResult;

  static List<Topic> _memoVisible(List<Topic> topics, Set<String> blocked) {
    if (identical(_visibleSrc, topics) &&
        identical(_visibleBlockedRef, blocked) &&
        _visibleResult != null) {
      return _visibleResult!;
    }
    _visibleSrc = topics;
    _visibleBlockedRef = blocked;
    return _visibleResult = BlockedUserFilter.visibleTopics(topics, blocked);
  }

  static List<Topic>? _summariesSrc;
  static List<BookmarkNameSummary>? _summariesResult;

  static List<BookmarkNameSummary> _memoSummaries(List<Topic> topics) {
    if (identical(_summariesSrc, topics) && _summariesResult != null) {
      return _summariesResult!;
    }
    _summariesSrc = topics;
    return _summariesResult = buildBookmarkNameSummaries(topics);
  }

  static List<Topic>? _filterSrc;
  static String? _filterKey;
  static List<Topic>? _filterResult;

  static List<Topic> _memoFiltered(List<Topic> topics, String? name) {
    if (identical(_filterSrc, topics) &&
        _filterKey == name &&
        _filterResult != null) {
      return _filterResult!;
    }
    _filterSrc = topics;
    _filterKey = name;
    return _filterResult = filterBookmarksByName(topics, name);
  }

  /// 卡片 widget 实例签名缓存(首页 _topicItemCache 同款机制):分页
  /// 落地/页面 setState 引发的 delegate 重建里,签名未变的卡返回同一
  /// widget 实例 → Element.updateChild 短路,零重建。签名涵盖构建
  /// 入参:topic(恒等)、长按开关、元信息宽、名称建议(identity)、
  /// 提醒过期态(色带颜色依赖 now,过期翻转须重建)。缓存的 item 持有
  /// 构建时的回调闭包 —— 闭包捕获的是稳定的页面 State,行为等价
  /// (首页同款先例)。
  static final Map<String, ({Object sig, Widget item})> _itemCache = {};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 话题卡自定义样式:改设置触发 rebuild(自绘排版直读全局快照,
    // stamp 变化换新实例);widget 路径进 sig 防命中旧卡
    ref.watch(preferencesProvider.select((p) => p.topicCardStyle));
    return DesktopRefreshIndicator(
      onRefresh: onRefresh,
      child: bookmarksAsync.when(
        data: (topics) => _buildDataContent(
          context,
          _memoVisible(
            topics,
            ref.watch(
              preferencesProvider.select((p) => p.normalizedBlockedUsernames),
            ),
          ),
          // 列表层订阅一次分类表传给每张卡,取代每张 TopicCard 各自
          // ref.watch(categoryMapProvider)(快滚双卡同帧就是双份订阅+
          // 依赖注册)。首页早有此优化,书签页此前漏了
          ref.watch(categoryMapProvider).value,
        ),
        loading: () => const TopicListSkeleton(),
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: onRefresh),
      ),
    );
  }

  Widget _buildDataContent(
    BuildContext context,
    List<Topic> topics,
    Map<int, Category>? categoryMap,
  ) {
    if (topics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Symbols.bookmark_rounded, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.bookmarks_empty,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final summaries = _memoSummaries(topics);
    final filteredTopics = _memoFiltered(topics, selectedBookmarkName);
    // 每卡入参一次性算好(此前在 itemBuilder 里逐卡算 + 逐卡注册
    // MediaQuery 依赖)
    final double? statsAvailableWidth = Responsive.isMobile(context)
        ? MediaQuery.sizeOf(context).width - 88
        : null;
    final listView = ListView.builder(
      controller: scrollController,
      // 书签卡无 keepalive 使用者,默认的 AutomaticKeepAlive 两层 State
      // 对滚动单卡首建是纯税(与首页话题列表同款处理)
      addAutomaticKeepAlives: false,
      // 顶部 padding 由上方 summary bar（如有）接管，避免双重间距；非工作区模式
      // 下若不显示 summary bar，下方 swipeRegion 直接返回 listView，仍走全 12。
      // 底部让出 extendBody 注入的底栏高度。
      padding: EdgeInsets.fromLTRB(
        12,
        showSummaryBar ? 8 : 12,
        12,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: filteredTopics.length + 1,
      itemBuilder: (context, index) {
        if (filteredTopics.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                context.l10n.search_noResults,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          );
        }

        if (index == filteredTopics.length) {
          return _buildFooter(context);
        }

        final topic = filteredTopics[index];
        final reminderAt = topic.bookmarkReminderAt;
        final reminderExpired =
            reminderAt != null && reminderAt.isBefore(DateTime.now());

        // ── 自绘卡路径(默认):整卡 1 个 RenderObject,排版在
        // TopicCardLayout 全局缓存里一次算死,挂载帧纯绘制 1~2ms。
        // widget 版路径保留在 else 分支(kUsePaintedCard=false 一键回退)
        if (kUsePaintedTopicCard && !topic.pinned) {
          final theme = Theme.of(context);
          final categoryId = int.tryParse(topic.categoryId);
          // 桌面端对齐 widget 版 buildTopicItem 的列宽约束:内容居中、
          // 卡宽 ≤ maxContentWidth;排版宽随之
          final viewportWidth = MediaQuery.sizeOf(context).width - 24;
          final isMobile = Responsive.isMobile(context);
          final cardWidth = isMobile
              ? viewportWidth
              : (viewportWidth > Breakpoints.maxContentWidth
                  ? Breakpoints.maxContentWidth
                  : viewportWidth);
          final layout = TopicCardLayout.obtain(
            identity: bookmarkTopicIdentity(topic),
            topic: topic,
            width: cardWidth,
            theme: theme,
            category: categoryMap?[categoryId],
            excerptText: _cleanedExcerptOf(topic),
            bandName: normalizeBookmarkName(topic.bookmarkName),
            bandReminder: reminderAt == null
                ? null
                : (reminderExpired
                    ? context.l10n.bookmarks_expired
                    : ' ${TimeUtils.formatDetailTime(reminderAt)}'),
            bandExpired: reminderExpired,
            statsAvailableWidth: statsAvailableWidth ?? 460,
            emojiUrlOf: topicCardEmojiUrlResolver,
          );
          Widget card = PaintedTopicCard(
            key: ValueKey(bookmarkTopicIdentity(topic)),
            layout: layout,
            onTap: () => onTap(topic),
            onMiddleClick: () => onMiddleClick(topic),
            onLongPress: enableLongPress
                ? () => TopicPreviewDialog.show(
                      context,
                      topic: topic,
                      onOpen: () => onTap(topic),
                      actions: topic.bookmarkId != null
                          ? _buildPreviewActions(context, topic)
                          : null,
                      customActionPanelBuilder: topic.bookmarkId != null
                          ? (_) => BookmarkPreviewQuickEditor(
                                initialName: topic.bookmarkName,
                                suggestions: bookmarkNameSuggestions,
                                suggestionsLoader: bookmarkNameSuggestionsLoader,
                                onSave: (value) =>
                                    onQuickRenameBookmark(topic, value),
                              )
                          : null,
                    )
                : null,
          );
          if (!isMobile) {
            card = Center(
              child: SizedBox(width: cardWidth, child: card),
            );
          }
          return card;
        }

        // 提醒过期态进签名:色带颜色依赖 now,跨过提醒时刻要重建。
        // 主题恒等也进签名:色带/摘要的颜色在构造参数里烤死(不同于
        // 卡内 build 时现读),深浅色切换必须换代。
        final sig = (
          topic: topic,
          enableLongPress: enableLongPress,
          statsAvailableWidth: statsAvailableWidth,
          suggestions: bookmarkNameSuggestions,
          reminderExpired: reminderExpired,
          themeId: identityHashCode(Theme.of(context)),
          categoryMap: categoryMap,
          cardStyle: TopicCardStyleScope.current,
        );
        final cacheKey = bookmarkTopicIdentity(topic);
        final hit = _itemCache[cacheKey];
        if (hit != null && hit.sig == sig) {
          return hit.item;
        }
        final item = buildTopicItem(
          context: context,
          topic: topic,
          isSelected: false,
          onTap: () => onTap(topic),
          onMiddleClick: () => onMiddleClick(topic),
          enableLongPress: enableLongPress,
          statsAvailableWidth: statsAvailableWidth,
          categoryMap: categoryMap,
          topWidget: _buildBookmarkTopBar(context, topic),
          middleWidget: _buildBookmarkExcerpt(context, topic),
          previewCustomActionPanelBuilder: topic.bookmarkId != null
              ? (_) => BookmarkPreviewQuickEditor(
                  initialName: topic.bookmarkName,
                  suggestions: bookmarkNameSuggestions,
                  suggestionsLoader: bookmarkNameSuggestionsLoader,
                  onSave: (value) => onQuickRenameBookmark(topic, value),
                )
              : null,
          previewActions: topic.bookmarkId != null
              ? _buildPreviewActions(context, topic)
              : null,
        );
        if (_itemCache.length > 600) _itemCache.clear();
        _itemCache[cacheKey] = (sig: sig, item: item);
        return item;
      },
    );

    final swipeRegion = _BookmarkFilterSwipeRegion(
      summaries: summaries,
      selectedBookmarkName: selectedBookmarkName,
      onSelectedBookmarkName: onSelectedBookmarkName,
      child: listView,
    );

    if (!showSummaryBar) {
      return swipeRegion;
    }

    final theme = Theme.of(context);
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: theme.colorScheme.surface),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: _BookmarkSummaryBar(
              summaries: summaries,
              selectedBookmarkName: selectedBookmarkName,
              onSelectedBookmarkName: onSelectedBookmarkName,
            ),
          ),
        ),
        Expanded(child: swipeRegion),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    return PagedListFooter(
      hasMore: hasMore,
      isLoadingMore: isLoadingMore,
      isLoadMoreFailed: isLoadMoreFailed,
      onRetry: onRetryLoadMore,
    );
  }

  List<PreviewAction> _buildPreviewActions(BuildContext context, Topic topic) {
    final theme = Theme.of(context);
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) {
      return [];
    }

    return [
      PreviewAction(
        icon: Symbols.edit_rounded,
        label: context.l10n.bookmark_editBookmark,
        onTap: () => onEditBookmark(topic),
      ),
      if (topic.bookmarkReminderAt != null)
        PreviewAction(
          icon: Symbols.alarm_off_rounded,
          label: context.l10n.bookmarks_cancelReminder,
          onTap: () => onClearReminder(topic),
        ),
      PreviewAction(
        icon: Symbols.delete_rounded,
        label: context.l10n.common_deleteBookmark,
        color: theme.colorScheme.error,
        onTap: () => onDeleteBookmark(topic),
      ),
    ];
  }

  Widget? _buildBookmarkTopBar(BuildContext context, Topic topic) {
    final bookmarkName = normalizeBookmarkName(topic.bookmarkName);
    final hasName = bookmarkName != null;
    final hasReminder = topic.bookmarkReminderAt != null;
    if (!hasName && !hasReminder) {
      return null;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final isExpired =
        hasReminder && topic.bookmarkReminderAt!.isBefore(DateTime.now());
    final backgroundColor = isExpired
        ? colorScheme.errorContainer.withValues(alpha: 0.5)
        : colorScheme.secondaryContainer.withValues(alpha: 0.6);
    final foregroundColor = isExpired
        ? colorScheme.error
        : colorScheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: backgroundColor,
      child: Text.rich(
        TextSpan(
          children: [
            if (hasName) ...[
              // 字形 span 替代 WidgetSpan(Icon):见 iconGlyphSpan 注释
              iconGlyphSpan(
                context,
                Symbols.bookmark_rounded,
                size: 13,
                color: foregroundColor,
              ),
              TextSpan(text: ' $bookmarkName'),
            ],
            if (hasReminder) ...[
              if (hasName)
                TextSpan(
                  text: '  ·  ',
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: 0.4),
                  ),
                ),
              iconGlyphSpan(
                context,
                Symbols.alarm_rounded,
                size: 13,
                color: foregroundColor,
              ),
              TextSpan(
                text: isExpired
                    ? context.l10n.bookmarks_expired
                    : ' ${TimeUtils.formatDetailTime(topic.bookmarkReminderAt!)}',
              ),
            ],
          ],
        ),
        style: TextStyle(fontSize: 12, color: foregroundColor, height: 1.3),
      ),
    );
  }

  /// 摘要清洗结果缓存(topic.id → (源串, 清洗结果)):正则+多趟 replaceAll
  /// 不便宜,itemBuilder 每次重建都重跑是纯税。以源串 identical 判失效
  /// (刷新拉到新数据 = 新字符串实例,自动重算)。
  static final Map<int, (String, String)> _excerptCleanCache = {};

  /// 清洗后的摘要文本(自绘卡路径直接用字符串;空串归 null)
  String? _cleanedExcerptOf(Topic topic) {
    final raw = topic.excerpt;
    if (raw == null) return null;
    final hit = _excerptCleanCache[topic.id];
    final String cleaned;
    if (hit != null && identical(hit.$1, raw)) {
      cleaned = hit.$2;
    } else {
      cleaned = _cleanExcerpt(raw);
      if (_excerptCleanCache.length > 500) _excerptCleanCache.clear();
      _excerptCleanCache[topic.id] = (raw, cleaned);
    }
    return cleaned.isEmpty ? null : cleaned;
  }

  Widget? _buildBookmarkExcerpt(BuildContext context, Topic topic) {
    final cleaned = _cleanedExcerptOf(topic);
    if (cleaned == null) {
      return null;
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      cleaned,
      style: TextStyle(
        fontSize: 12,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        height: 1.4,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _cleanExcerpt(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _BookmarkSummaryBar extends StatefulWidget {
  const _BookmarkSummaryBar({
    required this.summaries,
    required this.selectedBookmarkName,
    required this.onSelectedBookmarkName,
  });

  final List<BookmarkNameSummary> summaries;
  final String? selectedBookmarkName;
  final ValueChanged<String?> onSelectedBookmarkName;

  @override
  State<_BookmarkSummaryBar> createState() => _BookmarkSummaryBarState();
}

class _BookmarkSummaryBarState extends State<_BookmarkSummaryBar> {
  static const String _allSummaryKey = '__bookmark_summary_all__';

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _summaryKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant _BookmarkSummaryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensureSelectedChipVisible();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyForSummary(String key) {
    return _summaryKeys.putIfAbsent(key, GlobalKey.new);
  }

  String _selectedSummaryKey() {
    return widget.selectedBookmarkName ?? _allSummaryKey;
  }

  void _ensureSelectedChipVisible() {
    final key = _summaryKeys[_selectedSummaryKey()];
    final chipContext = key?.currentContext;
    if (chipContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      chipContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!PlatformUtils.isDesktop ||
        event is! PointerScrollEvent ||
        !_scrollController.hasClients) {
      return;
    }
    final delta = event.scrollDelta;
    final scrollDelta = delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
    if (scrollDelta == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final target = (_scrollController.offset + scrollDelta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chipChildren = <Widget>[
      KeyedSubtree(
        key: _keyForSummary(_allSummaryKey),
        child: ChoiceChip(
          label: Text(context.l10n.common_all),
          selected: widget.selectedBookmarkName == null,
          onSelected: (_) => widget.onSelectedBookmarkName(null),
        ),
      ),
      for (final summary in widget.summaries)
        KeyedSubtree(
          key: _keyForSummary(summary.filterKey),
          child: ChoiceChip(
            label: Text(
              summary.isUnset
                  ? '${context.l10n.common_notSet} (${summary.count})'
                  : summary.label,
            ),
            selected: widget.selectedBookmarkName == summary.filterKey,
            onSelected: (_) => widget.onSelectedBookmarkName(summary.filterKey),
          ),
        ),
    ];

    const spacing = SizedBox(width: 6);
    return Listener(
      key: const ValueKey('bookmark-summary-wheel-region'),
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          itemCount: chipChildren.length,
          separatorBuilder: (_, _) => spacing,
          itemBuilder: (_, index) => chipChildren[index],
        ),
      ),
    );
  }
}

class _BookmarkFilterSwipeRegion extends StatefulWidget {
  const _BookmarkFilterSwipeRegion({
    required this.summaries,
    required this.selectedBookmarkName,
    required this.onSelectedBookmarkName,
    required this.child,
  });

  final List<BookmarkNameSummary> summaries;
  final String? selectedBookmarkName;
  final ValueChanged<String?> onSelectedBookmarkName;
  final Widget child;

  @override
  State<_BookmarkFilterSwipeRegion> createState() =>
      _BookmarkFilterSwipeRegionState();
}

class _BookmarkFilterSwipeRegionState
    extends State<_BookmarkFilterSwipeRegion> {
  static const String _allSummaryKey = '__bookmark_summary_all__';
  static const double _swipeDistanceThreshold = 72;
  static const double _swipeVelocityThreshold = 320;

  double _horizontalDragDelta = 0;

  String _selectedSummaryKey() {
    return widget.selectedBookmarkName ?? _allSummaryKey;
  }

  List<String> _orderedSummaryKeys() {
    return [
      _allSummaryKey,
      ...widget.summaries.map((summary) => summary.filterKey),
    ];
  }

  void _selectSummaryByOffset(int offset) {
    if (offset == 0) {
      return;
    }
    final keys = _orderedSummaryKeys();
    final currentIndex = keys.indexOf(_selectedSummaryKey());
    if (currentIndex == -1) {
      return;
    }
    final nextIndex = (currentIndex + offset).clamp(0, keys.length - 1);
    if (nextIndex == currentIndex) {
      return;
    }
    final nextKey = keys[nextIndex];
    widget.onSelectedBookmarkName(nextKey == _allSummaryKey ? null : nextKey);
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    _horizontalDragDelta = 0;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    _horizontalDragDelta += details.primaryDelta ?? 0;
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (!PlatformUtils.isMobile) {
      _horizontalDragDelta = 0;
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    final delta = _horizontalDragDelta;
    _horizontalDragDelta = 0;

    if (delta <= -_swipeDistanceThreshold ||
        velocity <= -_swipeVelocityThreshold) {
      _selectSummaryByOffset(1);
      return;
    }
    if (delta >= _swipeDistanceThreshold ||
        velocity >= _swipeVelocityThreshold) {
      _selectSummaryByOffset(-1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('bookmark-content-swipe-region'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _handleHorizontalDragStart,
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: widget.child,
    );
  }
}
