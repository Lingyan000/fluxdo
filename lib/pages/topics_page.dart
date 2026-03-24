import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/pinned_categories_provider.dart';
import 'webview_login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/sort_and_tags_bar.dart';
import '../widgets/topic/filter_dropdown.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_notification_button.dart';
import '../widgets/topic/category_tab_manager_sheet.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/fading_edge_scroll_view.dart';
import '../widgets/offline_indicator.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';

class ScrollToTopNotifier extends StateNotifier<int> {
  ScrollToTopNotifier() : super(0);

  void trigger() => state++;
}

final scrollToTopProvider = StateNotifierProvider<ScrollToTopNotifier, int>((ref) {
  return ScrollToTopNotifier();
});

/// 顶栏/底栏可见性进度（0.0 = 完全隐藏, 1.0 = 完全显示）
final barVisibilityProvider = StateProvider<double>((ref) => 1.0);

/// FAB 是否处于刷新模式（用户正在向上滚动时为 true）
final fabRefreshModeProvider = StateProvider<bool>((ref) => false);

/// FAB 触发刷新信号
final fabRefreshSignalProvider = StateNotifierProvider<ScrollToTopNotifier, int>((ref) {
  return ScrollToTopNotifier();
});

/// Header 区域常量
const _searchBarHeight = 56.0;
const _tabRowHeight = 36.0;
const _sortBarHeight = 44.0;
const _collapsibleHeight = _searchBarHeight + _sortBarHeight; // 100

/// 阻止外层滚动的 ScrollPhysics，所有滑动增量转给内层列表。
class _NoOuterScrollPhysics extends ScrollPhysics {
  const _NoOuterScrollPhysics({super.parent});

  @override
  _NoOuterScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _NoOuterScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // 将全部增量当作越界返回，外层 position 不发生位移
    return value - position.pixels;
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // 禁止惯性动画，防止松手后外层回弹
    return null;
  }
}

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

class _TopicsPageState extends ConsumerState<TopicsPage> with TickerProviderStateMixin {
  late TabController _tabController;
  int _tabLength = 1; // 初始只有"全部"
  int _currentTabIndex = 0;
  List<int> _visiblePinnedIds = []; // 过滤后的可见分类 ID
  ScrollDirection? _lastOuterScrollDirection;

  final ScrollController _outerScrollController = ScrollController();
  AnimationController? _snapAnim;
  bool _isSnapping = false;
  bool _invalidateScheduled = false;
  Timer? _pointerScrollIdleTimer;
  bool _pointerScrolling = false;

  @override
  void initState() {
    super.initState();
    _visiblePinnedIds = ref.read(pinnedCategoriesProvider);
    _tabLength = 1 + _visiblePinnedIds.length;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  @override
  void dispose() {
    _snapAnim?.dispose();
    _pointerScrollIdleTimer?.cancel();
    _outerScrollController.dispose();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  /// 全局筛选/排序变化时：刷新当前 tab，非活跃 tab 标记 stale
  /// 使用微任务去抖，避免多个参数连续变化时重复请求（如登出时重置筛选+排序+方向）
  void _invalidateTopicTabs(List<int> pinnedIds) {
    if (_invalidateScheduled) return;
    _invalidateScheduled = true;
    Future.microtask(() {
      _invalidateScheduled = false;
      if (!mounted) return;
      final currentCategoryId = _currentCategoryId(pinnedIds);
      // 当前活跃 tab：调用 refresh() 显式设置纯 loading 状态，确保骨架屏显示
      ref.read(topicListProvider(currentCategoryId).notifier).refresh();
      // 非活跃 tab：标记 stale，切换时再刷新
      final staleTabs = <int?>{};
      for (final categoryId in [null, ...pinnedIds]) {
        if (categoryId == currentCategoryId) continue;
        staleTabs.add(categoryId);
      }
      final existing = ref.read(staleTabsProvider);
      ref.read(staleTabsProvider.notifier).state = {...existing, ...staleTabs};
    });
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_currentTabIndex == _tabController.index) return;
    setState(() {
      _currentTabIndex = _tabController.index;
    });
    final categoryId = _currentCategoryId();

    // 先处理 stale：在设置 currentTab 之前调用 refresh()，
    // 这样 widget rebuild 时 provider 已处于 loading 状态，不会闪旧数据
    final staleTabs = ref.read(staleTabsProvider);
    if (staleTabs.contains(categoryId)) {
      ref.read(topicListProvider(categoryId).notifier).refresh();
      ref.read(staleTabsProvider.notifier).state = staleTabs.difference({categoryId});
    }

    ref.read(currentTabCategoryIdProvider.notifier).state = categoryId;
  }

  /// 检测 pinnedCategories 变化，重建 TabController
  void _syncTabsIfNeeded(List<int> pinnedIds) {
    final desiredLength = 1 + pinnedIds.length;
    _visiblePinnedIds = pinnedIds;
    if (desiredLength == _tabLength) return;

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
      LoadingDialog.show(context, message: context.l10n.common_loadingData);

      AppStateRefresher.refreshAll(ref);

      try {
        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider(null).future),
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
        title: Text(context.l10n.topics_jumpToTopic),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.l10n.topics_topicId,
            hintText: context.l10n.topics_topicIdHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
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
            child: Text(context.l10n.topics_jump),
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
      final tabIndex = _visiblePinnedIds.indexOf(categoryId);
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
      ref.read(tabTagsProvider(categoryId).notifier).state = result;
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
  int? _currentCategoryId([List<int>? pinnedIds]) {
    if (_currentTabIndex == 0) return null;
    final List<int> ids = pinnedIds ?? _visiblePinnedIds;
    if (_currentTabIndex - 1 < ids.length) {
      return ids[_currentTabIndex - 1];
    }
    return null;
  }

  /// 构建排序栏右侧的按钮
  /// - 新/未读排序且已登录时：显示忽略按钮
  /// - 分类 Tab 且已登录时：显示分类通知按钮
  Widget? _buildTrailing(Category? category, bool isLoggedIn, TopicListFilter currentFilter) {
    // 新/未读筛选时显示忽略按钮
    if (isLoggedIn && (currentFilter == TopicListFilter.newTopics || currentFilter == TopicListFilter.unread)) {
      return _DismissButton(
        onPressed: () => _showDismissConfirmDialog(currentFilter),
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
        ref.read(categoryNotificationOverridesProvider.notifier).state = {
          ...ref.read(categoryNotificationOverridesProvider),
          category.id: newLevel.value,
        };
        try {
          final service = ref.read(discourseServiceProvider);
          await service.setCategoryNotificationLevel(category.id, newLevel.value);
        } catch (_) {
          // 失败时回退
          if (mounted) {
            final current = ref.read(categoryNotificationOverridesProvider);
            if (oldLevel != null) {
              ref.read(categoryNotificationOverridesProvider.notifier).state = {
                ...current,
                category.id: oldLevel,
              };
            } else {
              ref.read(categoryNotificationOverridesProvider.notifier).state =
                  Map.from(current)..remove(category.id);
            }
          }
        }
      },
    );
  }

  void _showDismissConfirmDialog(TopicListFilter currentFilter) {
    final label = currentFilter == TopicListFilter.newTopics ? context.l10n.topics_newTopics : context.l10n.topics_unreadTopics;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topics_dismissConfirmTitle),
        content: Text(context.l10n.topics_dismissConfirmContent(label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _doDismiss();
            },
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _doDismiss() async {
    final categoryId = _currentCategoryId();
    try {
      await ref.read(topicListProvider(categoryId).notifier).dismissAll();
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.common_operationFailed(e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final allPinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final categoryMap = categoryMapAsync.value;
    // 过滤掉当前用户无权限访问的分类（不在可见分类集合中的）
    final visibleIds = ref.watch(visibleCategoryIdsProvider);
    final pinnedIds = visibleIds != null
        ? allPinnedIds.where((id) => visibleIds.contains(id)).toList()
        : allPinnedIds;
    final currentFilter = ref.watch(topicFilterProvider);

    _syncTabsIfNeeded(pinnedIds);

    final currentCategoryId = _currentCategoryId(pinnedIds);
    final currentTags = ref.watch(tabTagsProvider(currentCategoryId));
    final currentCategory = _getCurrentCategory(pinnedIds, categoryMap);

    // 监听全局筛选/排序变化：刷新当前 tab，清除非活跃 tab 数据
    // 所有全局参数统一聚合在 topicListGlobalParamsSignal 中，
    // 未来新增参数只需在信号 provider 中添加 ref.watch
    ref.listen(topicListGlobalParamsSignal, (_, __) {
      _invalidateTopicTabs(pinnedIds);
    });

    // 关闭滚动折叠时，复位外层滚动到顶部
    ref.listen(preferencesProvider.select((p) => p.hideBarOnScroll), (prev, next) {
      if (!next &&
          _outerScrollController.hasClients &&
          _outerScrollController.positions.length == 1 &&
          _outerScrollController.offset > 0) {
        _outerScrollController.position.snapToPixels(0);
      }
    });

    // 监听滚动到顶部的通知
    ref.listen(scrollToTopProvider, (previous, next) {
      ref.read(fabRefreshModeProvider.notifier).state = false;
      // 通过 outer controller 的 animateTo 驱动 coordinator 统一动画。
      // 目标设为 outer 当前 offset，这样 coordinator 的 nestOffset 会：
      //   - outer → 保持当前位置（header 状态不变）
      //   - inner → 回到 minScrollExtent（列表回顶部）
      //
      // 不能调用 inner 的 animateTo(0)，因为 unnestOffset 的边界条件 bug
      // 会导致 coordinator 反而把 outer 推到 maxScrollExtent。
      if (_outerScrollController.hasClients && _outerScrollController.positions.length == 1) {
        _outerScrollController.animateTo(
          _outerScrollController.offset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    return Listener(
      onPointerDown: (_) => _cancelSnap(cancelPointerScrollSession: true),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && _shouldHandlePointerScroll(event)) {
          _onPointerScroll(event);
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleOuterScrollNotification,
        child: ScrollConfiguration(
          // 禁用自动 Scrollbar，避免 NestedScrollView + TabBarView
          // 多个 ScrollPosition 同时存在时 Scrollbar 报错
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ExtendedNestedScrollView(
          controller: _outerScrollController,
          floatHeaderSlivers: true,
          physics: ref.watch(preferencesProvider.select((p) => p.hideBarOnScroll))
              ? null
              : const _NoOuterScrollPhysics(),
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
                categoryMap: categoryMap ?? {},
                isLoggedIn: isLoggedIn,
                currentFilter: currentFilter,
                currentTags: currentTags,
                currentCategory: currentCategory,
                hideBarOnScroll: ref.watch(preferencesProvider).hideBarOnScroll,
                onFilterChanged: (filter) {
                  ref.read(topicFilterProvider.notifier).setFilter(filter);
                },
                onTagRemoved: (tag) {
                  final tags = ref.read(tabTagsProvider(currentCategoryId));
                  ref.read(tabTagsProvider(currentCategoryId).notifier).state =
                      tags.where((t) => t != tag).toList();
                },
                onAddTag: _openTagSelection,
                onTabTap: (index) {
                  if (index == _currentTabIndex) {
                    ref.read(scrollToTopProvider.notifier).trigger();
                  }
                },
                onCategoryManager: _openCategoryManager,
                onSearch: () {
                  SearchFilter? filter;
                  if (currentCategory != null) {
                    String? parentSlug;
                    if (currentCategory.parentCategoryId != null) {
                      parentSlug = categoryMap?[currentCategory.parentCategoryId]?.slug;
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
                trailing: _buildTrailing(currentCategory, isLoggedIn, currentFilter),
              ),
            ),
          ],
          body: Column(
            children: [
              const OfflineIndicator(),
              Expanded(
                child: TabBarView(
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
            ],
          ),
        ),
        ),
      ),
    );
  }

  bool _shouldHandlePointerScroll(PointerScrollEvent event) {
    if (kIsWeb) return false;
    if (!Platform.isMacOS) return false;
    final dx = event.scrollDelta.dx.abs();
    final dy = event.scrollDelta.dy.abs();
    return dy > dx;
  }

  bool _handleOuterScrollNotification(ScrollNotification notification) {
    // 用 UserScrollNotification 追踪用户主动滚动方向，避免回弹/惯性误触发
    if (notification is UserScrollNotification &&
        notification.metrics.axis == Axis.vertical) {
      if (notification.depth == 0) {
        _lastOuterScrollDirection = notification.direction;
      }
      if (notification.direction == ScrollDirection.forward) {
        // 向上滚动（朝顶部方向）→ 刷新模式
        if (!ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = true;
        }
      } else if (notification.direction == ScrollDirection.reverse) {
        // 向下滚动（深入列表）→ 创建模式
        if (ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = false;
        }
      }
    }

    // 内部列表到达顶部时恢复创建模式
    if (notification is ScrollUpdateNotification &&
        notification.depth > 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.metrics.pixels <= 0 &&
        ref.read(fabRefreshModeProvider)) {
      ref.read(fabRefreshModeProvider.notifier).state = false;
    }

    // snap 逻辑仅处理外层滚动
    if (notification.depth != 0) return false;

    // 拖拽滚动开始时，清理 pointer scroll 的状态，避免影响松手吸附。
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
    }

    if (notification is ScrollEndNotification && !_isSnapping) {
      // macOS 鼠标滚轮/触控板会产生大量离散的 ScrollEnd，若每次都立即 snap，
      // 会导致外层 header 在 0~阈值间反复吸附，从而表现为列表上下跳动。
      // pointer scrolling 期间跳过 snap，改由 onPointerSignal 的 idle 定时器统一触发一次。
      if (_pointerScrolling) return false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapOuterScroll();
      });
    }

    return false;
  }

  void _onPointerScroll(PointerScrollEvent event) {
    _cancelSnap();
    _pointerScrolling = true;
    _pointerScrollIdleTimer?.cancel();
    final delay = event.kind == PointerDeviceKind.mouse
        ? const Duration(milliseconds: 450)
        : const Duration(milliseconds: 250);
    _pointerScrollIdleTimer = Timer(delay, () {
      _pointerScrolling = false;
      if (!mounted || _isSnapping) return;
      _snapOuterScrollAfterPointerScroll();
    });
  }

  /// 取消正在进行的 snap
  void _cancelSnap({bool cancelPointerScrollSession = false}) {
    if (cancelPointerScrollSession) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
    }
    if (_isSnapping) {
      _snapAnim?.stop();
      _isSnapping = false;
    }
  }

  void _snapOuterScrollTo(double target) {
    if (!_outerScrollController.hasClients) return;
    if (_outerScrollController.positions.length != 1) return;

    final startOffset = _outerScrollController.offset;
    if (startOffset == target) return;

    _isSnapping = true;
    _snapAnim?.dispose();
    _snapAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    _snapAnim!.addListener(() {
      if (!_outerScrollController.hasClients) return;
      if (_outerScrollController.positions.length != 1) return;
      final t = Curves.easeOut.transform(_snapAnim!.value);
      final newOffset = startOffset + (target - startOffset) * t;
      _outerScrollController.position.snapToPixels(newOffset);
    });

    _snapAnim!.forward().whenComplete(() {
      _isSnapping = false;
    });
  }

  /// 松手后根据阈值吸附到完全展开或完全折叠。
  /// 使用 forcePixels 直接更新像素值，不通过 animateTo，
  /// 避免触发 coordinator 的 beginActivity/goIdle 导致内部列表位置重置。
  void _snapOuterScroll() {
    if (!_outerScrollController.hasClients) return;
    if (_outerScrollController.positions.length != 1) return;
    final offset = _outerScrollController.offset;

    // 关闭折叠时，始终吸附到顶部
    if (!ref.read(preferencesProvider).hideBarOnScroll) {
      if (offset > 0) {
        _outerScrollController.position.snapToPixels(0);
      }
      return;
    }

    if (offset <= 0 || offset >= _collapsibleHeight) return;

    final target = offset > _collapsibleHeight / 2 ? _collapsibleHeight : 0.0;
    _snapOuterScrollTo(target);
  }

  void _snapOuterScrollAfterPointerScroll() {
    if (!_outerScrollController.hasClients) return;
    if (_outerScrollController.positions.length != 1) return;
    final offset = _outerScrollController.offset;

    // 关闭折叠时，始终吸附到顶部
    if (!ref.read(preferencesProvider).hideBarOnScroll) {
      if (offset > 0) {
        _outerScrollController.position.snapToPixels(0);
      }
      return;
    }

    if (offset <= 0 || offset >= _collapsibleHeight) return;

    // pointer scroll（滚轮/触控板）更符合方向意图：向下则折叠，向上则展开。
    final direction = _lastOuterScrollDirection;
    final double target;
    if (direction == ScrollDirection.reverse) {
      target = _collapsibleHeight;
    } else if (direction == ScrollDirection.forward) {
      target = 0.0;
    } else {
      target = offset > _collapsibleHeight / 2 ? _collapsibleHeight : 0.0;
    }

    _snapOuterScrollTo(target);
  }

  /// 构建单个 tab 页面（带水平间距，圆角裁剪在列表内部处理）
  Widget _buildTabPage(int? categoryId) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12),
      child: _TopicList(
        key: ValueKey(categoryId),
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
  final TopicListFilter currentFilter;
  final List<String> currentTags;
  final Category? currentCategory;
  final ValueChanged<TopicListFilter> onFilterChanged;
  final ValueChanged<String> onTagRemoved;
  final VoidCallback onAddTag;
  final ValueChanged<int> onTabTap;
  final VoidCallback onCategoryManager;
  final VoidCallback onSearch;
  final VoidCallback onDebugTopicId;
  final Widget? trailing;
  final bool hideBarOnScroll;

  _TopicsHeaderDelegate({
    required this.statusBarHeight,
    required this.tabController,
    required this.pinnedIds,
    required this.categoryMap,
    required this.isLoggedIn,
    required this.currentFilter,
    required this.currentTags,
    required this.currentCategory,
    required this.onFilterChanged,
    required this.onTagRemoved,
    required this.onAddTag,
    required this.onTabTap,
    required this.onCategoryManager,
    required this.onSearch,
    required this.onDebugTopicId,
    this.trailing,
    this.hideBarOnScroll = true,
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
        currentFilter != oldDelegate.currentFilter ||
        currentTags != oldDelegate.currentTags ||
        currentCategory != oldDelegate.currentCategory ||
        trailing != oldDelegate.trailing ||
        hideBarOnScroll != oldDelegate.hideBarOnScroll;
  }

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final clampedOffset = shrinkOffset.clamp(0.0, _collapsibleHeight);

    // 搜索栏先折叠（shrinkOffset 0→56），排序栏后折叠（56→100）
    final searchProgress = (clampedOffset / _searchBarHeight).clamp(0.0, 1.0);
    final sortProgress = ((clampedOffset - _searchBarHeight) / _sortBarHeight).clamp(0.0, 1.0);

    // 更新 barVisibility（仅在值变化时才更新，避免快速滚动时的帧级联重建）
    final visibility = hideBarOnScroll
        ? (1.0 - clampedOffset / _collapsibleHeight).clamp(0.0, 1.0)
        : 1.0;
    final container = ProviderScope.containerOf(context, listen: false);
    final current = container.read(barVisibilityProvider);
    if ((visibility - current).abs() > 0.01) {
      final v = visibility;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        container.read(barVisibilityProvider.notifier).state = v;
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
                                      context.l10n.topics_searchHint,
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
                        if (isLoggedIn && !Responsive.showNavigationRail(context)) const NotificationIconButton(),
                        if (kDebugMode)
                          IconButton(
                            icon: const Icon(Icons.bug_report),
                            onPressed: onDebugTopicId,
                            tooltip: context.l10n.topics_debugJump,
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
                // 筛选/排序栏隐藏时，渐显筛选快捷按钮
                if (sortProgress > 0)
                  Opacity(
                    opacity: sortProgress,
                    child: FilterDropdown(
                      currentFilter: currentFilter,
                      isLoggedIn: isLoggedIn,
                      onFilterChanged: onFilterChanged,
                      style: DropdownStyle.compact,
                    ),
                  ),
                // 分类浏览按钮
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: const Icon(Icons.segment, size: 20),
                    onPressed: onCategoryManager,
                    tooltip: context.l10n.topics_browseCategories,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          // 筛选+排序+标签栏（完全折叠后跳过子树构建）
          if (sortProgress < 1.0)
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1.0 - sortProgress,
                child: Opacity(
                  opacity: 1.0 - sortProgress,
                  // 用 Consumer 局部读取排序状态，避免整个 header delegate 因排序变化而重建
                  child: Consumer(
                    builder: (context, ref, _) {
                      final order = ref.watch(topicSortOrderProvider);
                      final ascending = ref.watch(topicSortAscendingProvider);
                      return SortAndTagsBar(
                        currentFilter: currentFilter,
                        isLoggedIn: isLoggedIn,
                        onFilterChanged: onFilterChanged,
                        currentOrder: order,
                        ascending: ascending,
                        onOrderChanged: (o) => ref.read(topicSortOrderProvider.notifier).setOrder(o),
                        onToggleAscending: () => ref.read(topicSortAscendingProvider.notifier).toggle(),
                        selectedTags: currentTags,
                        onTagRemoved: onTagRemoved,
                        onAddTag: onAddTag,
                        trailing: trailing,
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Tab> _buildTabs() {
    final tabs = <Tab>[Tab(text: S.current.common_all)];
    for (final id in pinnedIds) {
      final category = categoryMap[id];
      tabs.add(Tab(text: category?.name ?? '...'));
    }
    return tabs;
  }
}

// ─── TopicList ───

/// 话题列表（每个 tab 一个实例，根据 categoryId + topicFilterProvider 获取数据）
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
  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();
  bool _isLoadingNewTopics = false;
  /// 需要高亮的话题 IDs（loadBefore 插入后设置，渐变消失后清除）
  final Set<int> _highlightedTopicIds = {};
  /// 本地缓存的话题数据，非当前 tab 时使用此缓存渲染，不订阅 provider
  AsyncValue<List<Topic>>? _cachedTopicsAsync;

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

  /// 清除当前 tab 的高亮和"新话题"计数
  void _clearIncomingState() {
    _highlightedTopicIds.clear();
    ref.read(latestChannelProvider.notifier).clearNewTopicsForCategory(widget.categoryId);
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

    final providerKey = widget.categoryId;
    final isCurrentTab = ref.watch(currentTabCategoryIdProvider) == widget.categoryId;

    // 当前 tab：watch provider 建立订阅，并缓存到本地
    // 非当前 tab：stale 显示 loading，否则显示缓存数据；均不订阅 provider
    final AsyncValue<List<Topic>> topicsAsync;
    if (isCurrentTab) {
      topicsAsync = ref.watch(topicListProvider(providerKey));
      _cachedTopicsAsync = topicsAsync;

      // 以下 listener 仅当前 tab 需要
      ref.listen(fabRefreshSignalProvider, (_, __) {
        _refreshIndicatorKey.currentState?.show();
      });
      ref.listen(tabTagsProvider(widget.categoryId), (prev, next) {
        if (prev != next) {
          ref.read(topicListProvider(widget.categoryId).notifier).refresh();
          _clearIncomingState();
        }
      });
      ref.listen(topicListGlobalParamsSignal, (_, __) {
        _clearIncomingState();
      });
    } else {
      // stale 时直接显示 loading，滑动动画中就能看到骨架屏
      final isStale = ref.watch(staleTabsProvider).contains(widget.categoryId);
      topicsAsync = isStale
          ? const AsyncValue.loading()
          : (_cachedTopicsAsync ?? const AsyncValue.loading());
    }

    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;

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
                children: [
                  const SizedBox(height: 100),
                  Center(child: Text(context.l10n.topics_noTopics)),
                ],
              ),
            ),
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final currentFilter = ref.read(topicFilterProvider);
        final hasNewTopics = currentFilter == TopicListFilter.latest
            && incomingState.hasIncomingForCategory(widget.categoryId);
        final newTopicCount = incomingState.incomingCountForCategory(widget.categoryId);
        final newTopicOffset = hasNewTopics ? 1 : 0;

        return RefreshIndicator(
          key: _refreshIndicatorKey,
          onRefresh: () async {
            try {
              // ignore: unused_result
              await ref.refresh(topicListProvider(providerKey).future);
            } catch (_) {}
            if (ref.read(topicFilterProvider) == TopicListFilter.latest) {
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
                itemCount: topics.length + newTopicOffset + 1,
                itemBuilder: (context, index) {
                  if (hasNewTopics && index == 0) {
                    return _buildNewTopicIndicator(context, newTopicCount, providerKey);
                  }

                  final topicIndex = index - newTopicOffset;
                  if (topicIndex >= topics.length) {
                    final notifier = ref.watch(topicListProvider(providerKey).notifier);
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: notifier.isLoadMoreFailed
                            ? GestureDetector(
                                onTap: () => notifier.retryLoadMore(),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.refresh, size: 16, color: Theme.of(context).colorScheme.primary),
                                    const SizedBox(width: 6),
                                    Text(
                                      context.l10n.common_loadFailedTapRetry,
                                      style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.primary),
                                    ),
                                  ],
                                ),
                              )
                            : notifier.hasMore
                                ? const CircularProgressIndicator()
                                : Text(context.l10n.common_noMore, style: const TextStyle(color: Colors.grey)),
                      ),
                    );
                  }

                  final topic = topics[topicIndex];
                  final enableLongPress = ref.watch(preferencesProvider).longPressPreview;
                  final shouldHighlight = _highlightedTopicIds.contains(topic.id);

                  if (shouldHighlight) {
                    final theme = Theme.of(context);
                    // 卡片正常背景色（需与 TopicCard / CompactTopicCard 的默认 color 一致）
                    final normalColor = topic.pinned
                        ? theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5)
                        : theme.cardTheme.color ?? theme.colorScheme.surfaceContainerHighest;
                    final highlightColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.3);
                    return TweenAnimationBuilder<Color?>(
                      key: ValueKey('highlight_${topic.id}'),
                      tween: ColorTween(begin: highlightColor, end: normalColor),
                      duration: const Duration(milliseconds: 2000),
                      curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
                      onEnd: () => _highlightedTopicIds.remove(topic.id),
                      builder: (context, color, _) {
                        return buildTopicItem(
                          context: context,
                          topic: topic,
                          isSelected: topic.id == selectedTopicId,
                          onTap: () => _openTopic(topic),
                          enableLongPress: enableLongPress,
                          highlightColor: color,
                        );
                      },
                    );
                  }

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
        child: const TopicListSkeleton(
          padding: EdgeInsets.only(top: 8, bottom: 12),
        ),
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

  Widget _buildNewTopicIndicator(BuildContext context, int count, int? providerKey) {
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
              // 对齐网页版 showInserted：按 topic_ids 增量加载并插入顶部
              final incomingState = ref.read(latestChannelProvider);
              final topicIds = incomingState.incomingTopicIdsForCategory(providerKey);
              final insertedIds = await ref.read(topicListProvider(providerKey).notifier).loadBefore(topicIds);
              ref.read(latestChannelProvider.notifier).clearIncoming(topicIds);

              if (mounted && insertedIds.isNotEmpty) {
                // 标记插入的话题以显示高亮动画
                _highlightedTopicIds.addAll(insertedIds);
                // 定时清除高亮，避免不可见卡片的动画无法触发 onEnd
                final idsToRemove = insertedIds.toSet();
                Future.delayed(const Duration(milliseconds: 2500), () {
                  if (!mounted) return;
                  final hadHighlights = _highlightedTopicIds.intersection(idsToRemove).isNotEmpty;
                  _highlightedTopicIds.removeAll(idsToRemove);
                  if (hadHighlights) setState(() {});
                });
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
                          context.l10n.topics_viewNewTopics(count),
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
                context.l10n.topics_dismiss,
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
