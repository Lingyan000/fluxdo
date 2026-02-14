part of '../topics_page.dart';

// ─── Header Delegate ───

/// 自定义 SliverPersistentHeaderDelegate
/// 包含搜索栏（可折叠）+ Tab 行（始终可见）+ 排序栏（可折叠）
class _TopicsHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double statusBarHeight;
  final TabController tabController;
  final List<int> pinnedIds;
  final Map<int, Category> categoryMap;
  final bool isLoggedIn;
  final TopicListFilter currentSort;
  final List<String> currentTags;
  final Category? currentCategory;
  final ValueChanged<TopicListFilter> onSortChanged;
  final ValueChanged<String> onTagRemoved;
  final VoidCallback onAddTag;
  final ValueChanged<int> onTabTap;
  final VoidCallback onCategoryManager;
  final VoidCallback onSearch;
  final VoidCallback onDebugTopicId;
  final VoidCallback? onRefresh;
  final Widget? trailing;

  _TopicsHeaderDelegate({
    required this.statusBarHeight,
    required this.tabController,
    required this.pinnedIds,
    required this.categoryMap,
    required this.isLoggedIn,
    required this.currentSort,
    required this.currentTags,
    required this.currentCategory,
    required this.onSortChanged,
    required this.onTagRemoved,
    required this.onAddTag,
    required this.onTabTap,
    required this.onCategoryManager,
    required this.onSearch,
    required this.onDebugTopicId,
    this.onRefresh,
    this.trailing,
  });

  @override
  double get maxExtent => statusBarHeight + _searchBarHeight + _tabRowHeight + _sortBarHeight;

  @override
  double get minExtent => statusBarHeight + _tabRowHeight;

  @override
  bool shouldRebuild(covariant _TopicsHeaderDelegate oldDelegate) {
    return statusBarHeight != oldDelegate.statusBarHeight ||
        tabController != oldDelegate.tabController ||
        pinnedIds != oldDelegate.pinnedIds ||
        categoryMap != oldDelegate.categoryMap ||
        isLoggedIn != oldDelegate.isLoggedIn ||
        currentSort != oldDelegate.currentSort ||
        currentTags != oldDelegate.currentTags ||
        currentCategory != oldDelegate.currentCategory ||
        trailing != oldDelegate.trailing;
  }

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final clampedOffset = shrinkOffset.clamp(0.0, _collapsibleHeight);

    // 搜索栏先折叠（shrinkOffset 0→56），排序栏后折叠（56→100）
    final searchProgress = (clampedOffset / _searchBarHeight).clamp(0.0, 1.0);
    final sortProgress = ((clampedOffset - _searchBarHeight) / _sortBarHeight).clamp(0.0, 1.0);

    // 更新 barVisibility（仅在值变化时才更新，避免快速滚动时的帧级联重建）
    final visibility = (1.0 - clampedOffset / _collapsibleHeight).clamp(0.0, 1.0);
    final container = ProviderScope.containerOf(context, listen: false);
    final current = container.read(barVisibilityProvider);
    if ((visibility - current).abs() > 0.01) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        container.read(barVisibilityProvider.notifier).set(visibility);
      });
    }

    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return Container(
      color: bgColor,
      child: Column(
        children: [
          // 状态栏
          SizedBox(height: statusBarHeight),
          // 搜索栏（完全折叠后跳过子树构建）
          if (searchProgress < 1.0)
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1.0 - searchProgress,
                child: Opacity(
                  opacity: 1.0 - searchProgress,
                  child: SizedBox(
                    height: _searchBarHeight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8, left: 16, right: 16, bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: onSearch,
                              child: Container(
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                children: [
                                  Icon(Icons.search, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '搜索话题...',
                                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (isLoggedIn) const NotificationIconButton(),
                        if (kDebugMode)
                          IconButton(
                            icon: const Icon(Icons.bug_report),
                            onPressed: onDebugTopicId,
                            tooltip: '调试：跳转话题',
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Tab 行（始终可见）
          SizedBox(
            height: _tabRowHeight,
            child: Row(
              children: [
                Expanded(
                  child: FadingEdgeScrollView(
                    child: TabBar(
                      controller: tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: _buildTabs(),
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                      indicatorSize: TabBarIndicatorSize.label,
                      dividerColor: Colors.transparent,
                      onTap: onTabTap,
                    ),
                  ),
                ),
                // 排序栏隐藏时，渐显排序快捷按钮
                if (sortProgress > 0)
                  Opacity(
                    opacity: sortProgress,
                    child: SortDropdown(
                      currentSort: currentSort,
                      isLoggedIn: isLoggedIn,
                      onSortChanged: onSortChanged,
                      style: SortDropdownStyle.compact,
                    ),
                  ),
                // 刷新按钮（桌面端无法下拉刷新）
                if (onRefresh != null && !Responsive.isMobile(context))
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: onRefresh,
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                  ),
                // 分类浏览按钮
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: const Icon(Icons.segment, size: 20),
                    onPressed: onCategoryManager,
                    tooltip: '浏览分类',
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          // 排序+标签栏（完全折叠后跳过子树构建）
          if (sortProgress < 1.0)
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1.0 - sortProgress,
                child: Opacity(
                  opacity: 1.0 - sortProgress,
                  child: SortAndTagsBar(
                    currentSort: currentSort,
                    isLoggedIn: isLoggedIn,
                    onSortChanged: onSortChanged,
                    selectedTags: currentTags,
                    onTagRemoved: onTagRemoved,
                    onAddTag: onAddTag,
                    trailing: trailing,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Tab> _buildTabs() {
    final tabs = <Tab>[const Tab(text: '全部')];
    for (final id in pinnedIds) {
      final category = categoryMap[id];
      tabs.add(Tab(text: category?.name ?? '...'));
    }
    return tabs;
  }
}
