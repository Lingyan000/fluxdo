import 'dart:async';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/pinned_categories_provider.dart';
import '../providers/topic_sort_provider.dart';
import 'webview_login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/sort_and_tags_bar.dart';
import '../widgets/topic/sort_dropdown.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_notification_button.dart';
import '../widgets/topic/category_tab_manager_sheet.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/fading_edge_scroll_view.dart';
import '../utils/responsive.dart';

class ScrollToTopNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void trigger() => state++;
}

final scrollToTopProvider = NotifierProvider<ScrollToTopNotifier, int>(
  ScrollToTopNotifier.new,
);

/// 顶栏/底栏可见性进度（0.0 = 完全隐藏, 1.0 = 完全显示）
class BarVisibilityNotifier extends Notifier<double> {
  @override
  double build() => 1.0;

  void set(double value) => state = value;
}

final barVisibilityProvider = NotifierProvider<BarVisibilityNotifier, double>(
  BarVisibilityNotifier.new,
);

/// Header 区域常量
const _searchBarHeight = 56.0;
const _tabRowHeight = 36.0;
const _sortBarHeight = 44.0;
const _collapsibleHeight = _searchBarHeight + _sortBarHeight; // 100

/// 暴露 forcePixels 用于 snap 动画的扩展。
/// 使用 forcePixels 而非 animateTo，避免触发 NestedScrollView coordinator
/// 的 beginActivity/goIdle 导致内部列表位置重置。
extension _ScrollPositionForcePixels on ScrollPosition {
  void snapToPixels(double value) {
    // ignore: invalid_use_of_protected_member
    forcePixels(value);
  }
}

// ─── TopicsPage ───

/// 帖子列表页面 - 分类 Tab + 排序下拉 + 标签 Chips
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key});

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  int _tabLength = 1; // 初始只有"全部"
  int _currentTabIndex = 0;
  final Map<int?, GlobalKey<_TopicListState>> _listKeys = {};

  final ScrollController _outerScrollController = ScrollController();
  Timer? _snapTimer;
  AnimationController? _snapAnim;
  bool _isSnapping = false;

  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    _tabLength = 1 + pinnedIds.length;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _outerScrollController.addListener(_scheduleSnap);
  }

  @override
  void didChangeMetrics() {
    // 屏幕尺寸变化时（旋转、折叠屏展开等）重置滚动位置，
    // 避免 SliverPersistentHeader 高度变化导致 UI 错位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orientation = MediaQuery.orientationOf(context);
      if (_lastOrientation != null && _lastOrientation != orientation) {
        if (_outerScrollController.hasClients) {
          _outerScrollController.jumpTo(0);
        }
        _cancelSnap();
        ref.read(barVisibilityProvider.notifier).set(1.0);
      }
      _lastOrientation = orientation;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _snapTimer?.cancel();
    _snapAnim?.dispose();
    _outerScrollController.removeListener(_scheduleSnap);
    _outerScrollController.dispose();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_currentTabIndex == _tabController.index) return;
    setState(() {
      _currentTabIndex = _tabController.index;
    });
    ref.read(currentTabCategoryIdProvider.notifier).set(_currentCategoryId());
  }

  /// 检测 pinnedCategories 变化，重建 TabController
  void _syncTabsIfNeeded(List<int> pinnedIds) {
    final desiredLength = 1 + pinnedIds.length;
    if (desiredLength == _tabLength) return;

    // 清理已移除分类的 key
    final activeCategoryIds = <int?>{null, ...pinnedIds};
    _listKeys.removeWhere((key, _) => !activeCategoryIds.contains(key));

    final oldIndex = _tabController.index;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tabLength = desiredLength;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _currentTabIndex = oldIndex < _tabLength ? oldIndex : 0;
    _tabController.index = _currentTabIndex;
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
    );
    if (result == true && mounted) {
      LoadingDialog.show(context, message: '加载数据...');

      AppStateRefresher.refreshAll(ref);

      try {
        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider((TopicListFilter.latest, null)).future),
        ]).timeout(const Duration(seconds: 10));
      } catch (_) {}

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  void _showTopicIdDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到话题'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '话题 ID',
            hintText: '例如: 1095754',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(controller.text.trim());
              Navigator.pop(context);
              if (id != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TopicDetailPage(
                      topicId: id,
                      autoSwitchToMasterDetail: true,
                    ),
                  ),
                );
              }
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }

  void _openCategoryManager() async {
    final categoryId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CategoryTabManagerSheet(),
    );

    // 如果返回了 category ID，切换到对应的 Tab
    if (categoryId != null && mounted) {
      final pinnedIds = ref.read(pinnedCategoriesProvider);
      final tabIndex = pinnedIds.indexOf(categoryId);
      if (tabIndex >= 0) {
        _tabController.animateTo(tabIndex + 1); // +1 因为"全部"在 index 0
      }
    }
  }

  Future<void> _openTagSelection() async {
    final categoryId = _currentCategoryId();
    final currentTags = ref.read(tabTagsProvider(categoryId));
    final tagsAsync = ref.read(tagsProvider);
    final availableTags = tagsAsync.when(
      data: (tags) => tags,
      loading: () => <String>[],
      error: (e, s) => <String>[],
    );

    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        categoryId: categoryId,
        availableTags: availableTags,
        selectedTags: currentTags,
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      ref.read(tabTagsProvider(categoryId).notifier).set(result);
    }
  }

  /// 获取当前选中分类 Tab 对应的 Category（仅非"全部"时返回）
  Category? _getCurrentCategory(List<int> pinnedIds, Map<int, Category>? categoryMap) {
    if (_currentTabIndex == 0 || categoryMap == null) return null;
    if (_currentTabIndex - 1 >= pinnedIds.length) return null;
    final categoryId = pinnedIds[_currentTabIndex - 1];
    return categoryMap[categoryId];
  }

  /// 获取当前 tab 对应的 categoryId
  int? _currentCategoryId() {
    if (_currentTabIndex == 0) return null;
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    if (_currentTabIndex - 1 < pinnedIds.length) {
      return pinnedIds[_currentTabIndex - 1];
    }
    return null;
  }

  /// 获取指定 categoryId 的 GlobalKey
  GlobalKey<_TopicListState> _getListKey(int? categoryId) {
    return _listKeys.putIfAbsent(categoryId, () => GlobalKey<_TopicListState>());
  }

  /// 构建排序栏右侧的按钮
  /// - 新/未读排序且已登录时：显示忽略按钮
  /// - 分类 Tab 且已登录时：显示分类通知按钮
  Widget? _buildTrailing(Category? category, bool isLoggedIn, TopicListFilter currentSort) {
    // 新/未读排序时显示忽略按钮
    if (isLoggedIn && (currentSort == TopicListFilter.newTopics || currentSort == TopicListFilter.unread)) {
      return _DismissButton(
        onPressed: () => _showDismissConfirmDialog(currentSort),
      );
    }

    if (category == null || !isLoggedIn) return null;
    // 优先使用共享覆盖值，否则取服务端返回值
    final overrides = ref.watch(categoryNotificationOverridesProvider);
    final effectiveLevel = overrides[category.id] ?? category.notificationLevel;
    final level = CategoryNotificationLevel.fromValue(effectiveLevel);
    return CategoryNotificationButton(
      level: level,
      onChanged: (newLevel) async {
        final oldLevel = effectiveLevel;
        // 乐观更新
        ref.read(categoryNotificationOverridesProvider.notifier).set({
          ...ref.read(categoryNotificationOverridesProvider),
          category.id: newLevel.value,
        });
        try {
          final service = ref.read(discourseServiceProvider);
          await service.setCategoryNotificationLevel(category.id, newLevel.value);
        } catch (_) {
          // 失败时回退
          if (mounted) {
            final current = ref.read(categoryNotificationOverridesProvider);
            if (oldLevel != null) {
              ref.read(categoryNotificationOverridesProvider.notifier).set({
                ...current,
                category.id: oldLevel,
              });
            } else {
              ref.read(categoryNotificationOverridesProvider.notifier).set(
                  Map.from(current)..remove(category.id),
              );
            }
          }
        }
      },
    );
  }

  void _showDismissConfirmDialog(TopicListFilter currentSort) {
    final label = currentSort == TopicListFilter.newTopics ? '新话题' : '未读话题';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('忽略确认'),
        content: Text('确定要忽略全部$label吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _doDismiss();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _doDismiss() async {
    final currentSort = ref.read(topicSortProvider);
    final categoryId = _currentCategoryId();
    final providerKey = (currentSort, categoryId);
    try {
      await ref.read(topicListProvider(providerKey).notifier).dismissAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final currentSort = ref.watch(topicSortProvider);
    final currentCategoryId = _currentCategoryId();
    final currentTags = ref.watch(tabTagsProvider(currentCategoryId));

    _syncTabsIfNeeded(pinnedIds);

    final currentCategory = _getCurrentCategory(pinnedIds, categoryMapAsync.value);

    // 监听滚动到顶部的通知
    ref.listen(scrollToTopProvider, (previous, next) {
      _outerScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      _getListKey(_currentCategoryId()).currentState?.scrollToTop();
    });

    return Listener(
      onPointerDown: (_) => _cancelSnap(),
      child: ExtendedNestedScrollView(
      controller: _outerScrollController,
      floatHeaderSlivers: true,
      pinnedHeaderSliverHeightBuilder: () => topPadding + _tabRowHeight,
      onlyOneScrollInBody: true,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverPersistentHeader(
          pinned: true,
          floating: true,
          delegate: _TopicsHeaderDelegate(
            statusBarHeight: topPadding,
            tabController: _tabController,
            pinnedIds: pinnedIds,
            categoryMap: categoryMapAsync.value ?? {},
            isLoggedIn: isLoggedIn,
            currentSort: currentSort,
            currentTags: currentTags,
            currentCategory: currentCategory,
            onSortChanged: (sort) {
              ref.read(topicSortProvider.notifier).set(sort);
            },
            onTagRemoved: (tag) {
              final tags = ref.read(tabTagsProvider(currentCategoryId));
              ref.read(tabTagsProvider(currentCategoryId).notifier).set(
                  tags.where((t) => t != tag).toList(),
                );
            },
            onAddTag: _openTagSelection,
            onTabTap: (index) {
              if (index == _currentTabIndex) {
                _getListKey(_currentCategoryId()).currentState?.scrollToTop();
              }
            },
            onCategoryManager: _openCategoryManager,
            onSearch: () {
              SearchFilter? filter;
              if (currentCategory != null) {
                String? parentSlug;
                if (currentCategory.parentCategoryId != null) {
                  parentSlug = categoryMapAsync.value?[currentCategory.parentCategoryId]?.slug;
                }
                filter = SearchFilter(
                  categoryId: currentCategory.id,
                  categorySlug: currentCategory.slug,
                  categoryName: currentCategory.name,
                  parentCategorySlug: parentSlug,
                );
              }
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SearchPage(initialFilter: filter)),
              );
            },
            onDebugTopicId: () => _showTopicIdDialog(context),
            onRefresh: () {
              final providerKey = (currentSort, currentCategoryId);
              ref.invalidate(topicListProvider(providerKey));
            },
            trailing: _buildTrailing(currentCategory, isLoggedIn, currentSort),
          ),
        ),
      ],
      body: TabBarView(
        controller: _tabController,
        children: [
          ExtendedVisibilityDetector(
            uniqueKey: const Key('tab_all'),
            child: _buildTabPage(null),
          ),
          for (int i = 0; i < pinnedIds.length; i++)
            ExtendedVisibilityDetector(
              uniqueKey: Key('tab_${pinnedIds[i]}'),
              child: _buildTabPage(pinnedIds[i]),
            ),
        ],
      ),
      ),
    );
  }

  /// outer scroll 位置变化时，重置定时器；
  /// 位置停止变化 150ms 后触发 snap 判定。
  void _scheduleSnap() {
    if (_isSnapping) return; // snap 动画期间的 forcePixels 触发，忽略
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(milliseconds: 30), () {
      if (mounted) _snapOuterScroll();
    });
  }

  /// 取消正在进行的 snap
  void _cancelSnap() {
    _snapTimer?.cancel();
    if (_isSnapping) {
      _snapAnim?.stop();
      _isSnapping = false;
    }
  }

  /// 松手后根据阈值吸附到完全展开或完全折叠。
  /// 使用 forcePixels 直接更新像素值，不通过 animateTo，
  /// 避免触发 coordinator 的 beginActivity/goIdle 导致内部列表位置重置。
  void _snapOuterScroll() {
    if (!_outerScrollController.hasClients) return;
    final offset = _outerScrollController.offset;
    if (offset <= 0 || offset >= _collapsibleHeight) return;

    final target = offset > _collapsibleHeight / 2 ? _collapsibleHeight : 0.0;
    final startOffset = offset;

    _isSnapping = true;
    _snapAnim?.dispose();
    _snapAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    _snapAnim!.addListener(() {
      if (!_outerScrollController.hasClients) return;
      final t = Curves.easeOut.transform(_snapAnim!.value);
      final newOffset = startOffset + (target - startOffset) * t;
      _outerScrollController.position.snapToPixels(newOffset);
    });

    _snapAnim!.forward().whenComplete(() {
      _isSnapping = false;
    });
  }

  /// 构建单个 tab 页面（带水平间距，圆角裁剪在列表内部处理）
  Widget _buildTabPage(int? categoryId) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12),
      child: _TopicList(
        key: _getListKey(categoryId),
        categoryId: categoryId,
        onLoginRequired: _goToLogin,
      ),
    );
  }
}

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

// ─── TopicList ───

/// 话题列表（每个 tab 一个实例，根据 categoryId + topicSortProvider 获取数据）
class _TopicList extends ConsumerStatefulWidget {
  final VoidCallback onLoginRequired;
  final int? categoryId;

  const _TopicList({
    super.key,
    required this.onLoginRequired,
    this.categoryId,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList>
    with AutomaticKeepAliveClientMixin {
  bool _isLoadingNewTopics = false;

  @override
  bool get wantKeepAlive => true;

  /// 列表区域顶部圆角
  static const _topBorderRadius = BorderRadius.only(
    topLeft: Radius.circular(12),
    topRight: Radius.circular(12),
  );

  void scrollToTop() {
    final controller = PrimaryScrollController.maybeOf(context);
    controller?.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _openTopic(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref.read(selectedTopicProvider.notifier).select(
        topicId: topic.id,
        initialTitle: topic.title,
        scrollToPostNumber: topic.lastReadPostNumber,
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 需要
    final currentSort = ref.watch(topicSortProvider);
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;
    final providerKey = (currentSort, widget.categoryId);
    final topicsAsync = ref.watch(topicListProvider(providerKey));

    return topicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async {
              try {
                // ignore: unused_result
                await ref.refresh(topicListProvider(providerKey).future);
              } catch (_) {}
            },
            child: ClipRRect(
              borderRadius: _topBorderRadius,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: const [
                  SizedBox(height: 100),
                  Center(child: Text('没有相关话题')),
                ],
              ),
            ),
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final hasNewTopics = currentSort == TopicListFilter.latest
            && incomingState.hasIncomingForCategory(widget.categoryId);
        final newTopicCount = incomingState.incomingCountForCategory(widget.categoryId);
        final newTopicOffset = hasNewTopics ? 1 : 0;

        return RefreshIndicator(
          onRefresh: () async {
            try {
              // ignore: unused_result
              await ref.refresh(topicListProvider(providerKey).future);
            } catch (_) {}
            if (currentSort == TopicListFilter.latest) {
              ref.read(latestChannelProvider.notifier).clearNewTopicsForCategory(widget.categoryId);
            }
          },
          child: ClipRRect(
            borderRadius: _topBorderRadius,
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200) {
                  ref.read(topicListProvider(providerKey).notifier).loadMore();
                }
                return false;
              },
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                cacheExtent: 1000,
                itemCount: topics.length + newTopicOffset + 1,
                itemBuilder: (context, index) {
                  if (hasNewTopics && index == 0) {
                    return _buildNewTopicIndicator(context, newTopicCount, providerKey);
                  }

                  final topicIndex = index - newTopicOffset;
                  if (topicIndex >= topics.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: ref.watch(topicListProvider(providerKey).notifier).hasMore
                            ? const CircularProgressIndicator()
                            : const Text('没有更多了', style: TextStyle(color: Colors.grey)),
                      ),
                    );
                  }

                  final topic = topics[topicIndex];
                  final enableLongPress = ref.watch(preferencesProvider).longPressPreview;

                  return buildTopicItem(
                    context: context,
                    topic: topic,
                    isSelected: topic.id == selectedTopicId,
                    onTap: () => _openTopic(topic),
                    enableLongPress: enableLongPress,
                  );
                },
              ),
            ),
          ),
        );
      },
      loading: () => ClipRRect(
        borderRadius: _topBorderRadius,
        child: const TopicListSkeleton(),
      ),
      error: (error, stack) => ClipRRect(
        borderRadius: _topBorderRadius,
        child: ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: () => ref.refresh(topicListProvider(providerKey)),
        ),
      ),
    );
  }

  Widget _buildNewTopicIndicator(BuildContext context, int count, (TopicListFilter, int?) providerKey) {
    final scrollController = PrimaryScrollController.maybeOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics ? null : () async {
            setState(() {
              _isLoadingNewTopics = true;
            });
            try {
              await ref.read(topicListProvider(providerKey).notifier).silentRefresh();
              ref.read(latestChannelProvider.notifier).clearNewTopicsForCategory(providerKey.$2);

              if (mounted) {
                scrollController?.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            } finally {
              if (mounted) {
                setState(() {
                  _isLoadingNewTopics = false;
                });
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _isLoadingNewTopics
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_upward,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '有 $count 条新话题，点击刷新',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
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

/// 忽略按钮（紧凑 chip 样式，参考 CategoryNotificationButton）
class _DismissButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _DismissButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.3);
    final fgColor = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check, size: 14, color: fgColor),
              const SizedBox(width: 4),
              Text(
                '忽略',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
