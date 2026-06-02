import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/preferences_provider.dart';
import '../utils/pagination_helper.dart';
import '../utils/topic_keyword_filter.dart';
import '../widgets/topic/keyword_filter_hint_bar.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/sort_and_tags_bar.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/common/error_view.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import 'package:dio/dio.dart';
import '../services/app_error_handler.dart';
import '../l10n/s.dart';
import '../widgets/desktop_refresh_indicator.dart';

/// 标签话题列表页面
class TagTopicsPage extends ConsumerStatefulWidget {
  final String tagName;

  const TagTopicsPage({super.key, required this.tagName});

  @override
  ConsumerState<TagTopicsPage> createState() => _TagTopicsPageState();
}

class _TagTopicsPageState extends ConsumerState<TagTopicsPage> {
  final ScrollController _scrollController = ScrollController();
  List<Topic> _topics = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _isLoadMoreFailed = false;
  bool _hasMore = true;
  int _page = 0;
  Object? _error;

  // 本地筛选、排序状态（初始值从持久化偏好读取）
  late TopicListFilter _currentFilter;
  late NewSubset _currentSubset;
  TopicSortOrder _currentOrder = TopicSortOrder.defaultOrder;
  bool _ascending = false;

  static final _paginationHelper = PaginationHelpers.forTopics<Topic>(
    keyExtractor: (topic) => topic.id,
  );

  @override
  void initState() {
    super.initState();
    _currentFilter = ref.read(topicFilterProvider);
    _currentSubset = ref.read(topicNewSubsetProvider);
    _currentOrder = ref.read(topicSortOrderProvider);
    _ascending = ref.read(topicSortAscendingProvider);
    _scrollController.addListener(_onScroll);
    _loadTopics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 关键词过滤场景下，loadMore 自动续加载的并发标志
  bool _isAutoContinueLoading = false;

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreWithAutoContinue();
    }
  }

  /// 触发 loadMore；若关键词命中率高、可见增量不足，自动续加载至多 3 次。
  Future<void> _loadMoreWithAutoContinue() async {
    if (_isAutoContinueLoading) return;
    _isAutoContinueLoading = true;
    try {
      final prefs = ref.read(preferencesProvider);
      final keywords = prefs.normalizedFilterKeywords;
      final wholeWord = prefs.topicFilterWholeWord;

      var attempts = 0;
      while (true) {
        final (visBefore, _) = TopicKeywordFilter.apply(
          _topics,
          normalizedKeywords: keywords,
          wholeWord: wholeWord,
        );
        await _loadMore();
        if (!mounted) return;
        final (visAfter, _) = TopicKeywordFilter.apply(
          _topics,
          normalizedKeywords: keywords,
          wholeWord: wholeWord,
        );
        if (!TopicKeywordFilter.shouldAutoLoadMore(
          visibleBefore: visBefore.length,
          visibleAfter: visAfter.length,
          hasMore: _hasMore,
          attempts: attempts,
        )) {
          break;
        }
        attempts++;
      }
    } finally {
      _isAutoContinueLoading = false;
    }
  }

  Future<void> _loadTopics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final response = await service.getFilteredTopics(
        filter: _currentFilter.filterName,
        tags: [widget.tagName],
        period: _currentFilter.period,
        page: 0,
        order: _currentOrder.apiValue,
        ascending: _currentOrder != TopicSortOrder.defaultOrder
            ? _ascending
            : null,
        subset: _currentFilter == TopicListFilter.newTopics
            ? _currentSubset.apiValue
            : null,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      if (mounted) {
        setState(() {
          _topics = result.items;
          _hasMore = result.hasMore;
          _page = 0;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  /// 静默刷新（不显示 loading）
  Future<void> _silentRefresh() async {
    try {
      final service = ref.read(discourseServiceProvider);
      final response = await service.getFilteredTopics(
        filter: _currentFilter.filterName,
        tags: [widget.tagName],
        period: _currentFilter.period,
        page: 0,
        order: _currentOrder.apiValue,
        ascending: _currentOrder != TopicSortOrder.defaultOrder
            ? _ascending
            : null,
        subset: _currentFilter == TopicListFilter.newTopics
            ? _currentSubset.apiValue
            : null,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      if (mounted) {
        setState(() {
          _topics = result.items;
          _hasMore = result.hasMore;
          _page = 0;
        });
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadMoreFailed) return;
    if (!_hasMore || _isLoadingMore || _isLoading) return;

    setState(() => _isLoadingMore = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final nextPage = _page + 1;
      final response = await service.getFilteredTopics(
        filter: _currentFilter.filterName,
        tags: [widget.tagName],
        period: _currentFilter.period,
        page: nextPage,
        order: _currentOrder.apiValue,
        ascending: _currentOrder != TopicSortOrder.defaultOrder
            ? _ascending
            : null,
        subset: _currentFilter == TopicListFilter.newTopics
            ? _currentSubset.apiValue
            : null,
      );

      final currentState = PaginationState(items: _topics);
      final result = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      if (mounted) {
        setState(() {
          _hasMore = result.hasMore;
          if (result.items.length > _topics.length) {
            _page = nextPage;
          }
          _topics = result.items;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _isLoadMoreFailed = true;
        });
      }
    }
  }

  void _setFilter(TopicListFilter filter) {
    if (filter == _currentFilter) return;
    setState(() => _currentFilter = filter);
    ref.read(topicFilterProvider.notifier).setFilter(filter);
    _loadTopics();
  }

  void _setSubset(NewSubset subset) {
    if (subset == _currentSubset) return;
    setState(() => _currentSubset = subset);
    ref.read(topicNewSubsetProvider.notifier).setSubset(subset);
    _loadTopics();
  }

  void _setOrder(TopicSortOrder order) {
    if (order == _currentOrder) return;
    setState(() => _currentOrder = order);
    _loadTopics();
  }

  void _toggleAscending() {
    setState(() => _ascending = !_ascending);
    _loadTopics();
  }

  Future<void> _openTopic(Topic topic) async {
    // 标签详情页是独立 push 的页面，不在首页 MasterDetailLayout 内，
    // 始终 push 全屏详情页，禁用 autoSwitchToMasterDetail 防止双栏模式下自动 pop。
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );

    // 从话题详情返回后，静默刷新
    if (mounted) {
      _silentRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.tagName}'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  initialFilter: SearchFilter(tags: [widget.tagName]),
                ),
              ),
            ),
            tooltip: context.l10n.common_search,
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选 + 排序栏（不需要标签选择功能）
          SortAndTagsBar(
            currentFilter: _currentFilter,
            isLoggedIn: isLoggedIn,
            onFilterChanged: _setFilter,
            currentSubset: _currentSubset,
            onSubsetChanged: _setSubset,
            currentOrder: _currentOrder,
            ascending: _ascending,
            onOrderChanged: _setOrder,
            onToggleAscending: _toggleAscending,
            selectedTags: const [],
            onTagRemoved: (_) {},
          ),
          // 列表
          Expanded(child: _buildBody(selectedTopicId)),
        ],
      ),
    );
  }

  Widget _buildBody(int? selectedTopicId) {
    if (_isLoading) {
      return const TopicListSkeleton(padding: EdgeInsets.all(12));
    }

    if (_error != null) {
      return ErrorView(error: _error!, onRetry: _loadTopics);
    }

    if (_topics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(context.l10n.tagTopics_empty),
          ],
        ),
      );
    }

    final keywords = ref.watch(
      preferencesProvider.select((p) => p.normalizedFilterKeywords),
    );
    final wholeWord = ref.watch(
      preferencesProvider.select((p) => p.topicFilterWholeWord),
    );
    final (visible, hidden) = TopicKeywordFilter.apply(
      _topics,
      normalizedKeywords: keywords,
      wholeWord: wholeWord,
    );
    final hintOffset = hidden > 0 ? 1 : 0;

    return DesktopRefreshIndicator(
      onRefresh: _loadTopics,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: visible.length + hintOffset + 1,
        itemBuilder: (context, index) {
          if (hintOffset > 0 && index == 0) {
            return KeywordFilterHintBar(hiddenCount: hidden);
          }
          final topicIndex = index - hintOffset;
          if (topicIndex >= visible.length) {
            if (!_hasMore) {
              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    context.l10n.common_noMore,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              );
            }
            if (_isLoadMoreFailed) {
              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _isLoadMoreFailed = false);
                      _loadMore();
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.refresh,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          context.l10n.common_loadFailedTapRetry,
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final topic = visible[topicIndex];
          final enableLongPress = ref
              .watch(preferencesProvider)
              .longPressPreview;

          return buildTopicItem(
            context: context,
            topic: topic,
            isSelected: topic.id == selectedTopicId,
            onTap: () => _openTopic(topic),
            enableLongPress: enableLongPress,
          );
        },
      ),
    );
  }
}
