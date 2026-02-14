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

part 'topics_page/_header_delegate.dart';
part 'topics_page/_topic_list.dart';

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
      } catch (e) {
        debugPrint('[TopicsPage] Initial data loading failed: $e');
      }

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
