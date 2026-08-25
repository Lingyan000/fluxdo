import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/topic.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/discourse/discourse_service.dart';
import '../../utils/paged_async_notifier.dart';
import '../../utils/pagination_helper.dart';
import '../core_providers.dart';
import '../category_provider.dart';
import '../message_bus/topic_tracking_providers.dart';
import 'filter_provider.dart';
import 'sort_provider.dart';
import 'tab_state_provider.dart';

/// 话题列表 Notifier (支持分页、静默刷新和筛选)
class TopicListNotifier extends AsyncNotifier<List<Topic>>
    with PagedAsyncNotifierMixin<Topic> {
  TopicListNotifier(this._categoryId);

  final int? _categoryId;

  /// 分页助手
  static final _paginationHelper = PaginationHelpers.forTopics<Topic>(
    keyExtractor: (topic) => topic.id,
  );

  @override
  Future<List<Topic>> build() async {
    // 话题列表里每张卡的已读状态是拉取那一刻的快照,之后只有
    // topicTrackingStateProvider(MessageBus /latest /unread /read 频道
    // 实时更新)会变,列表卡本身不会跟着刷新——来了新回复数字不涨,
    // 在网页/别的设备读完了红点也一直挂着。这里订阅追踪状态,把变化
    // 双向同步回当前显示的话题上,不需要用户手动下拉刷新整个列表。
    ref.listen<Map<int, TrackedTopicState>>(topicTrackingStateProvider, (
      previous,
      next,
    ) {
      _syncFromTrackingState(next);
    });

    // 所有参数使用 ref.read（不建立依赖），
    // 由 UI 层在参数变化时主动 invalidate provider
    final currentFilter = ref.read(topicFilterProvider);
    final tags = ref.read(tabTagsProvider(_categoryId));
    final filter = _buildFilterParams(tags);
    final sortOrder = ref.read(topicSortOrderProvider);
    final sortAscending = ref.read(topicSortAscendingProvider);

    resetPagingState();

    // 获取排序 API 参数
    final orderParam = sortOrder.apiValue;
    final ascendingParam = orderParam != null ? sortAscending : null;

    // 「新话题」子过滤
    final subset = currentFilter == TopicListFilter.newTopics
        ? ref.read(topicNewSubsetProvider).apiValue
        : null;

    // 优化：如果是 latest 列表且没有筛选条件且没有自定义排序，优先同步使用预加载数据
    // 这样可以避免显示 loading 状态
    if (currentFilter == TopicListFilter.latest &&
        filter.isEmpty &&
        orderParam == null) {
      final preloadedService = PreloadedDataService();
      final preloadedData = preloadedService.getInitialTopicListSync();
      if (preloadedData != null) {
        final result = _paginationHelper.processRefresh(
          PaginationResult(
            items: preloadedData.topics,
            moreUrl: preloadedData.moreTopicsUrl,
          ),
        );
        return completePagedRefresh(PagedPage.fromPagination(result));
      }
      if (preloadedService.hasInitialTopicList) {
        final asyncPreloaded = await preloadedService.getInitialTopicList();
        if (asyncPreloaded != null) {
          final result = _paginationHelper.processRefresh(
            PaginationResult(
              items: asyncPreloaded.topics,
              moreUrl: asyncPreloaded.moreTopicsUrl,
            ),
          );
          return completePagedRefresh(PagedPage.fromPagination(result));
        }
      }
    }

    // 如果没有预加载数据，走正常的异步流程
    final service = ref.read(discourseServiceProvider);
    final response = await _fetchTopics(
      service,
      currentFilter,
      0,
      filter,
      order: orderParam,
      ascending: ascendingParam,
      subset: subset,
    );

    final result = _paginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    return completePagedRefresh(PagedPage.fromPagination(result));
  }

  Future<TopicListResponse> _fetchTopics(
    DiscourseService service,
    TopicListFilter filter,
    int page,
    TopicFilterParams filterParams, {
    String? order,
    bool? ascending,
    String? subset,
  }) {
    // 如果有筛选条件，使用 getFilteredTopics
    if (filterParams.isNotEmpty) {
      final filterName = _getFilterName(filter);
      return service.getFilteredTopics(
        filter: filterName,
        categoryId: filterParams.categoryId,
        categorySlug: filterParams.categorySlug,
        parentCategorySlug: filterParams.parentCategorySlug,
        tags: filterParams.tags.isNotEmpty ? filterParams.tags : null,
        period: filter.period,
        page: page,
        order: order,
        ascending: ascending,
        subset: subset,
      );
    }

    // 无筛选条件，使用原有方法
    switch (filter) {
      case TopicListFilter.latest:
        return service.getLatestTopics(
          page: page,
          order: order,
          ascending: ascending,
        );
      case TopicListFilter.newTopics:
        return service.getNewTopics(
          page: page,
          order: order,
          ascending: ascending,
          subset: subset,
        );
      case TopicListFilter.unread:
        return service.getUnreadTopics(
          page: page,
          order: order,
          ascending: ascending,
        );
      case TopicListFilter.unseen:
        return service.getUnseenTopics(
          page: page,
          order: order,
          ascending: ascending,
        );
      case TopicListFilter.top:
        return service.getTopTopics();
      case TopicListFilter.hot:
        return service.getHotTopics(
          page: page,
          order: order,
          ascending: ascending,
        );
    }
  }

  String _getFilterName(TopicListFilter filter) => filter.filterName;

  /// 根据分类 ID 和标签构建筛选参数
  TopicFilterParams _buildFilterParams(List<String> tags) {
    if (_categoryId == null && tags.isEmpty) {
      return const TopicFilterParams();
    }
    if (_categoryId != null) {
      final categoryMap = ref.read(categoryMapProvider).value ?? {};
      final category = categoryMap[_categoryId];
      String? parentSlug;
      if (category?.parentCategoryId != null) {
        parentSlug = categoryMap[category!.parentCategoryId]?.slug;
      }
      return TopicFilterParams(
        categoryId: _categoryId,
        categorySlug: category?.slug,
        categoryName: category?.name,
        parentCategorySlug: parentSlug,
        tags: tags,
      );
    }
    return TopicFilterParams(tags: tags);
  }

  /// 获取当前筛选参数（供非 build 方法使用）
  TopicFilterParams _currentFilterParams() {
    return _buildFilterParams(ref.read(tabTagsProvider(_categoryId)));
  }

  /// 获取当前筛选模式
  TopicListFilter get _currentFilter => ref.read(topicFilterProvider);

  /// 获取当前排序参数
  (String?, bool?) _currentSortParams() {
    final sortOrder = ref.read(topicSortOrderProvider);
    final orderParam = sortOrder.apiValue;
    final ascendingParam = orderParam != null
        ? ref.read(topicSortAscendingProvider)
        : null;
    return (orderParam, ascendingParam);
  }

  /// 刷新列表
  Future<void> refresh() async {
    await runPagedRefresh(() async {
      final service = ref.read(discourseServiceProvider);
      final filterParams = _currentFilterParams();
      final (order, ascending) = _currentSortParams();
      final subset = _currentFilter == TopicListFilter.newTopics
          ? ref.read(topicNewSubsetProvider).apiValue
          : null;
      final response = await _fetchTopics(
        service,
        _currentFilter,
        0,
        filterParams,
        order: order,
        ascending: ascending,
        subset: subset,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      return PagedPage.fromPagination(result);
    });
  }

  /// 静默刷新
  Future<void> silentRefresh() async {
    final service = ref.read(discourseServiceProvider);
    final filterParams = _currentFilterParams();
    final (order, ascending) = _currentSortParams();
    final subset = _currentFilter == TopicListFilter.newTopics
        ? ref.read(topicNewSubsetProvider).apiValue
        : null;
    try {
      final response = await _fetchTopics(
        service,
        _currentFilter,
        0,
        filterParams,
        order: order,
        ascending: ascending,
        subset: subset,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      state = AsyncValue.data(
        completePagedRefresh(PagedPage.fromPagination(result)),
      );
    } catch (e) {
      debugPrint('Silent refresh failed: $e');
    }
  }

  /// 按 topic_ids 加载并插入到列表顶部（对齐网页版 loadBefore）
  ///
  /// 1. 请求 /latest.json?topic_ids=xxx 获取这些话题的最新数据
  /// 2. 从当前列表中移除同 ID 旧数据（处理"更新的话题"）
  /// 3. 将 API 返回的话题全部插入列表顶部
  ///
  /// 返回实际被插入到顶部的 topic IDs（用于 UI 高亮）
  Future<List<int>> loadBefore(List<int> topicIds) async {
    if (topicIds.isEmpty) return [];
    final currentTopics = state.value;
    if (currentTopics == null) return [];

    try {
      final service = ref.read(discourseServiceProvider);
      final response = await service.getTopicsByIds(topicIds);
      final newTopics = response.topics;
      if (newTopics.isEmpty) return [];

      // 移除列表中已存在的同 ID 话题（刷新重复项，与网页版 removeValuesFromArray 一致）
      final newTopicIds = newTopics.map((t) => t.id).toSet();
      final remaining = currentTopics
          .where((t) => !newTopicIds.contains(t.id))
          .toList();
      // 将新话题全部插入列表顶部
      state = AsyncValue.data([...newTopics, ...remaining]);
      return newTopics.map((t) => t.id).toList();
    } catch (e) {
      debugPrint('[TopicList] loadBefore 失败: $e');
      return [];
    }
  }

  /// 加载更多
  Future<void> loadMore() async {
    await runPagedLoadMore((currentTopics, nextPage) async {
      final service = ref.read(discourseServiceProvider);
      final filterParams = _currentFilterParams();
      final (order, ascending) = _currentSortParams();
      final subset = _currentFilter == TopicListFilter.newTopics
          ? ref.read(topicNewSubsetProvider).apiValue
          : null;
      final response = await _fetchTopics(
        service,
        _currentFilter,
        nextPage,
        filterParams,
        order: order,
        ascending: ascending,
        subset: subset,
      );

      final currentState = PaginationState(items: currentTopics);
      final paginationResult = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      return PagedPage.fromPagination(
        paginationResult,
        advancePage: response.topics.isNotEmpty,
      );
    });
  }

  /// 手动重试加载更多
  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }

  /// 刷新单条话题状态（用于 MessageBus 更新）
  Future<void> refreshTopic(int topicId) async {
    final currentTopics = state.value;
    if (currentTopics == null) return;

    final existingIndex = currentTopics.indexWhere((t) => t.id == topicId);
    if (existingIndex == -1) {
      return;
    }
    final existingTopic = currentTopics[existingIndex];

    try {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(topicId);

      final updatedTopic = Topic(
        id: detail.id,
        title: detail.title,
        slug: detail.slug,
        categoryId: detail.categoryId.toString(),
        postsCount: detail.postsCount,
        replyCount: detail.postsCount > 0 ? detail.postsCount - 1 : 0,
        views: existingTopic.views,
        likeCount: existingTopic.likeCount,
        lastPostedAt: existingTopic.lastPostedAt,
        pinned: existingTopic.pinned,
        tags: detail.tags ?? existingTopic.tags,
        posters: existingTopic.posters,
        unseen: false,
        unread: 0,
        lastReadPostNumber: detail.postsCount,
        highestPostNumber: detail.postsCount,
        lastPosterUsername: detail.postStream.posts.isNotEmpty
            ? detail.postStream.posts.last.username
            : existingTopic.lastPosterUsername,
      );

      final newList = currentTopics.map((t) {
        return t.id == topicId ? updatedTopic : t;
      }).toList();

      state = AsyncValue.data(newList);
    } catch (e) {
      debugPrint('[TopicList] 刷新话题 $topicId 失败: $e');
    }
  }

  /// 忽略全部（新话题或未读话题）
  Future<void> dismissAll() async {
    final service = ref.read(discourseServiceProvider);
    final filter = _currentFilter;
    if (filter == TopicListFilter.newTopics) {
      final subset = ref.read(topicNewSubsetProvider);
      await service.dismissNewTopics(
        categoryId: _categoryId,
        dismissTopics: subset != NewSubset.replies,
        dismissPosts: subset != NewSubset.topics,
      );
      // 同步更新追踪状态计数（与服务端 dismiss 对齐）
      final trackingNotifier = ref.read(topicTrackingStateProvider.notifier);
      if (subset != NewSubset.replies) {
        trackingNotifier.dismissNewTopics(categoryId: _categoryId);
      }
      if (subset != NewSubset.topics) {
        trackingNotifier.dismissUnreadTopics(categoryId: _categoryId);
      }
    } else if (filter == TopicListFilter.unread) {
      await service.dismissUnreadTopics(categoryId: _categoryId);
      // 同步更新追踪状态计数
      ref
          .read(topicTrackingStateProvider.notifier)
          .dismissUnreadTopics(categoryId: _categoryId);
    }
    state = AsyncValue.data(
      completePagedRefresh(
        const PagedPage<Topic>(items: <Topic>[], hasMore: false),
      ),
    );
  }

  /// 用 topicTrackingStateProvider 的实时数据刷新当前列表里对应话题的
  /// 已读状态(见 build() 里的 ref.listen)。对齐网页版
  /// topic-tracking-state.js 的 updateTopics:双向同步——来新回复时
  /// 未读数上涨,在别端读完/忽略时红点下降或清除。
  ///
  /// tracking map 是全局单例,任何一个话题的消息都会让整个 map 换新
  /// 触发这个监听;长轮询重连还可能补发旧消息。防串扰不靠"只涨不落"
  /// 的整体守卫(那会把跨端已读的下降方向也挡死),而是两个游标各自
  /// 单调合并:highestPostNumber 与 lastReadPostNumber 都只取双方更
  /// 前进的一侧——旧消息重放两个游标都不倒退,自然不会出现"刚读完
  /// 又弹回未读";tracking 初值来自启动快照,可能落后于刚拉回的列表
  /// 数据,取 max 也堵住了未读数被旧快照算虚高的口子。
  void _syncFromTrackingState(Map<int, TrackedTopicState> tracking) {
    final topics = state.value;
    if (topics == null || tracking.isEmpty) return;

    List<Topic>? newList;
    for (var i = 0; i < topics.length; i++) {
      final topic = topics[i];
      final tracked = tracking[topic.id];
      if (tracked == null) continue;

      final highest = math.max(tracked.highestPostNumber, topic.highestPostNumber);
      final trackedLastRead = tracked.lastReadPostNumber;
      final topicLastRead = topic.lastReadPostNumber;
      final lastRead = trackedLastRead == null
          ? topicLastRead
          : (topicLastRead == null
                ? trackedLastRead
                : math.max(trackedLastRead, topicLastRead));

      // 未读数口径对齐服务端 lib/unread.rb:没读过的话题 unread 恒为 0
      // (它走 unseen/NEW 语义,不走未读计数)
      final newUnread = lastRead == null ? 0 : (highest - lastRead).clamp(0, highest);
      // 对齐网页版 updateTopics 的 unseen 回写:读过或已被忽略
      // (dismiss_new 置 isSeen)都不再算新话题
      final newUnseen = lastRead == null && !tracked.isSeen && topic.unseen;

      if (newUnread == topic.unread &&
          highest == topic.highestPostNumber &&
          lastRead == topicLastRead &&
          newUnseen == topic.unseen) {
        continue;
      }

      newList ??= [...topics];
      newList[i] = topic.copyWith(
        unseen: newUnseen,
        unread: newUnread,
        lastReadPostNumber: lastRead,
        highestPostNumber: highest,
      );
    }

    if (newList != null) {
      state = AsyncValue.data(newList);
    }
  }

  void updateSeen(int topicId, int highestSeen, {bool updateTracking = true}) {
    final topics = state.value;
    if (topics == null) return;

    final index = topics.indexWhere((t) => t.id == topicId);
    if (index == -1) return;

    final topic = topics[index];
    final currentRead = topic.lastReadPostNumber ?? 0;

    if (highestSeen <= currentRead) return;

    final newUnread = (topic.highestPostNumber - highestSeen).clamp(
      0,
      topic.highestPostNumber,
    );

    final newList = [...topics];
    newList[index] = topic.copyWith(
      unseen: false,
      unread: newUnread,
      newPosts: 0,
      lastReadPostNumber: highestSeen,
    );
    state = AsyncValue.data(newList);

    if (updateTracking) {
      // 同步更新追踪状态计数（阅读后减少 new/unread 计数）
      ref
          .read(topicTrackingStateProvider.notifier)
          .updateTopicRead(topicId, highestSeen, topic.highestPostNumber);
    }
  }

  /// 标记话题为未读:已读游标显式回退到 highest - 1(与服务端
  /// destroy_last_for 一致)。_syncFromTrackingState 的单调合并只认
  /// 前进方向,回退必须在这里直写列表项;tracking 侧由调用方另行回退,
  /// 两头游标落到同一位置后,后续合并两边等值不会互相顶回。
  /// [all] = true 清空整个游标,回 unseen/NEW 语义(unread 恒 0,
  /// 对齐 lib/unread.rb:没读过的话题不走未读计数)。
  void markUnread(int topicId, {bool all = false}) {
    final topics = state.value;
    if (topics == null) return;

    final index = topics.indexWhere((t) => t.id == topicId);
    if (index == -1) return;

    final topic = topics[index];
    final highest = topic.highestPostNumber;
    final lastRead = all ? null : (highest > 1 ? highest - 1 : null);

    final newList = [...topics];
    newList[index] = topic.copyWith(
      unseen: all,
      unread: lastRead == null ? 0 : (highest - lastRead).clamp(0, highest),
      newPosts: 0,
      lastReadPostNumber: lastRead,
      clearLastRead: lastRead == null,
    );
    state = AsyncValue.data(newList);
  }
}

final topicListProvider =
    AsyncNotifierProvider.family<TopicListNotifier, List<Topic>, int?>(
      TopicListNotifier.new,
    );

/// 热门话题 Provider
final topTopicsProvider = FutureProvider<TopicListResponse>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getTopTopics();
});
