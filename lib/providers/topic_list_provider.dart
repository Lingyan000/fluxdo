import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../services/preloaded_data_service.dart';
import '../services/discourse/discourse_service.dart';
import '../utils/pagination_helper.dart';
import 'core_providers.dart';
import 'category_provider.dart';
import 'topic_sort_provider.dart';

enum TopicListFilter {
  latest,
  newTopics,
  unread,
  top,
  hot,
}

/// TopicListFilter 扩展方法
extension TopicListFilterX on TopicListFilter {
  /// 获取 API 请求所用的过滤器名称
  String get filterName {
    switch (this) {
      case TopicListFilter.latest:
        return 'latest';
      case TopicListFilter.newTopics:
        return 'new';
      case TopicListFilter.unread:
        return 'unread';
      case TopicListFilter.top:
        return 'top';
      case TopicListFilter.hot:
        return 'top/weekly';
    }
  }
}

/// 话题筛选条件（内部使用）
class TopicFilterParams {
  final int? categoryId;
  final String? categorySlug;
  final String? categoryName;
  final String? parentCategorySlug;
  final List<String> tags;

  const TopicFilterParams({
    this.categoryId,
    this.categorySlug,
    this.categoryName,
    this.parentCategorySlug,
    this.tags = const [],
  });

  bool get isEmpty => categoryId == null && tags.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 话题列表 Notifier (支持分页、静默刷新和筛选)
class TopicListNotifier extends AsyncNotifier<List<Topic>> {
  TopicListNotifier(this.arg);

  final (TopicListFilter, int?) arg;

  TopicListFilter get _sort => arg.$1;
  int? get _categoryId => arg.$2;

  int _page = 0;
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  /// 分页助手
  static final _paginationHelper = PaginationHelpers.forTopics<Topic>(
    keyExtractor: (topic) => topic.id,
  );

  @override
  Future<List<Topic>> build() async {
    // 监听当前 tab 的标签变化
    final tags = ref.watch(tabTagsProvider(_categoryId));
    final filter = _buildFilterParams(tags);

    _page = 0;
    _hasMore = true;

    // 优化：如果是 latest 列表且没有筛选条件，优先同步使用预加载数据
    // 这样可以避免显示 loading 状态
    if (_sort == TopicListFilter.latest && filter.isEmpty) {
      final preloadedService = PreloadedDataService();
      final preloadedData = preloadedService.getInitialTopicListSync();
      if (preloadedData != null) {
        final result = _paginationHelper.processRefresh(
          PaginationResult(items: preloadedData.topics, moreUrl: preloadedData.moreTopicsUrl),
        );
        _hasMore = result.hasMore;
        return result.items;
      }
      if (preloadedService.hasInitialTopicList) {
        final asyncPreloaded = await preloadedService.getInitialTopicList();
        if (asyncPreloaded != null) {
          final result = _paginationHelper.processRefresh(
            PaginationResult(items: asyncPreloaded.topics, moreUrl: asyncPreloaded.moreTopicsUrl),
          );
          _hasMore = result.hasMore;
          return result.items;
        }
      }
    }

    // 如果没有预加载数据，走正常的异步流程
    final service = ref.read(discourseServiceProvider);
    final response = await _fetchTopics(service, _sort, 0, filter);

    final result = _paginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    _hasMore = result.hasMore;
    return result.items;
  }

  Future<TopicListResponse> _fetchTopics(
    DiscourseService service,
    TopicListFilter filter,
    int page,
    TopicFilterParams filterParams,
  ) {
    // 如果有筛选条件，使用 getFilteredTopics
    if (filterParams.isNotEmpty) {
      final filterName = _getFilterName(filter);
      return service.getFilteredTopics(
        filter: filterName,
        categoryId: filterParams.categoryId,
        categorySlug: filterParams.categorySlug,
        parentCategorySlug: filterParams.parentCategorySlug,
        tags: filterParams.tags.isNotEmpty ? filterParams.tags : null,
        page: page,
      );
    }

    // 无筛选条件，使用原有方法
    switch (filter) {
      case TopicListFilter.latest:
        return service.getLatestTopics(page: page);
      case TopicListFilter.newTopics:
        return service.getNewTopics(page: page);
      case TopicListFilter.unread:
        return service.getUnreadTopics(page: page);
      case TopicListFilter.top:
        return service.getTopTopics();
      case TopicListFilter.hot:
        return service.getHotTopics(page: page);
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

  /// 刷新列表
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      _page = 0;
      _hasMore = true;
      final service = ref.read(discourseServiceProvider);
      final filterParams = _currentFilterParams();
      final response = await _fetchTopics(service, _sort, 0, filterParams);

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );
      _hasMore = result.hasMore;
      return result.items;
    });
  }

  /// 静默刷新
  Future<void> silentRefresh() async {
    final service = ref.read(discourseServiceProvider);
    final filterParams = _currentFilterParams();
    try {
      final response = await _fetchTopics(service, _sort, 0, filterParams);
      _page = 0;

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );
      _hasMore = result.hasMore;
      state = AsyncValue.data(result.items);
    } catch (e) {
      debugPrint('Silent refresh failed: $e');
    }
  }

  /// 加载更多
  Future<void> loadMore() async {
    if (!_hasMore || state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncValue<List<Topic>>.loading().copyWithPrevious(state);

    state = await AsyncValue.guard(() async {
      final currentTopics = state.requireValue;
      final nextPage = _page + 1;

      final service = ref.read(discourseServiceProvider);
      final filterParams = _currentFilterParams();
      final response = await _fetchTopics(service, _sort, nextPage, filterParams);

      final currentState = PaginationState(items: currentTopics);
      final result = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );

      _hasMore = result.hasMore;
      if (result.items.length > currentTopics.length) {
        _page = nextPage;
      }
      return result.items;
    });
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

      final updatedTopic = existingTopic.copyWith(
        title: detail.title,
        slug: detail.slug,
        categoryId: detail.categoryId,
        postsCount: detail.postsCount,
        replyCount: detail.postsCount > 0 ? detail.postsCount - 1 : 0,
        tags: detail.tags ?? existingTopic.tags,
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
    if (_sort == TopicListFilter.newTopics) {
      await service.dismissNewTopics(categoryId: _categoryId);
    } else if (_sort == TopicListFilter.unread) {
      await service.dismissUnreadTopics(categoryId: _categoryId);
    }
    state = const AsyncValue.data([]);
    _hasMore = false;
  }

  void updateSeen(int topicId, int highestSeen) {
    final topics = state.value;
    if (topics == null) return;

    final index = topics.indexWhere((t) => t.id == topicId);
    if (index == -1) return;

    final topic = topics[index];
    final currentRead = topic.lastReadPostNumber ?? 0;

    if (highestSeen <= currentRead) return;

    final newUnread = (topic.highestPostNumber - highestSeen).clamp(0, topic.highestPostNumber);

    final updated = topic.copyWith(
      unseen: false,
      unread: newUnread,
      newPosts: 0,
      lastReadPostNumber: highestSeen,
    );

    final newList = [...topics];
    newList[index] = updated;
    state = AsyncValue.data(newList);
  }
}

final topicListProvider = AsyncNotifierProvider.family<TopicListNotifier, List<Topic>, (TopicListFilter, int?)>(
  TopicListNotifier.new,
);

/// 热门话题 Provider
final topTopicsProvider = FutureProvider<TopicListResponse>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getTopTopics();
});
