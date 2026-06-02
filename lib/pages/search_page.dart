import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/shortcut_binding.dart';
import '../providers/discourse_providers.dart';
import '../models/search_filter.dart';
import '../models/search_result.dart';
import '../services/preloaded_data_service.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/common/loading_spinner.dart';
import '../widgets/search/search_filter_panel.dart';
import '../widgets/search/search_post_card.dart';
import '../widgets/search/search_preview_dialog.dart';
import '../providers/preferences_provider.dart';
import '../providers/shortcut_provider.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'package:dio/dio.dart';
import '../services/app_error_handler.dart';
import '../l10n/s.dart';
import 'user_profile_page.dart';
import '../utils/dialog_utils.dart';

/// 搜索页面
class SearchPage extends ConsumerStatefulWidget {
  final String? initialQuery;
  final SearchFilter? initialFilter;

  const SearchPage({super.key, this.initialQuery, this.initialFilter});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  late final ShortcutSurfaceBinding _shortcutSurfaceBinding =
      ShortcutSurfaceBinding(
        ref: ref,
        id: ShortcutSurfaceIds.search,
        triggerAction: ShortcutAction.openSearch,
        kind: ShortcutSurfaceKind.route,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
        passthroughActions: ShortcutSurfaceActionSets.globalRoutePassthrough,
      );
  ModalRoute<dynamic>? _route;

  String _currentQuery = '';
  int _currentPage = 1;
  bool _isLoadingMore = false;
  List<SearchPost> _standardPosts = []; // 标准搜索结果（原始）
  List<SearchPost> _allPosts = []; // 最终展示列表（融合后）
  List<SearchUser> _allUsers = [];
  bool _hasMorePosts = false;
  bool _hasMoreUsers = false;
  bool _hasError = false;
  bool _isLoadMoreFailed = false;
  String _errorMessage = '';

  // 最近搜索记录
  List<String> _recentSearches = [];
  bool _isLoadingRecentSearches = true;
  bool _isClearingRecentSearches = false;

  // 高级过滤器
  late SearchFilter _filter;

  // AI 语义搜索
  bool _siteAiSearchAvailable = false;
  List<SearchPost> _aiPosts = []; // AI 搜索结果（原始）
  bool _isSearchingAi = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter ?? const SearchFilter();
    PreloadedDataService().isAiSemanticSearchEnabled().then((enabled) {
      if (mounted) setState(() => _siteAiSearchAvailable = enabled);
    });
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _searchController.text = widget.initialQuery!;
      _currentQuery = widget.initialQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performSearch();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
        _loadRecentSearches();
      });
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    _shortcutSurfaceBinding.registerDeferred(
      context,
      onClose: () => Navigator.of(context).maybePop(),
      onFocus: _revealSelf,
    );
  }

  void _revealSelf() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || route.isCurrent) return;
    navigator.popUntil((candidate) => identical(candidate, route));
  }

  /// 加载最近搜索记录
  Future<void> _loadRecentSearches() async {
    try {
      final service = ref.read(discourseServiceProvider);
      final searches = await service.getRecentSearches();
      if (mounted) {
        setState(() {
          _recentSearches = searches;
          _isLoadingRecentSearches = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingRecentSearches = false;
        });
      }
    }
  }

  /// 清空最近搜索记录
  Future<void> _clearRecentSearches() async {
    if (_isClearingRecentSearches) return;
    setState(() => _isClearingRecentSearches = true);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.clearRecentSearches();
      if (mounted) {
        setState(() {
          _recentSearches = [];
          _isClearingRecentSearches = false;
        });
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      if (mounted) {
        setState(() => _isClearingRecentSearches = false);
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        setState(() => _isClearingRecentSearches = false);
      }
    }
  }

  @override
  void dispose() {
    _shortcutSurfaceBinding.disposeDeferred();
    _searchController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        _hasMorePosts) {
      _loadMore();
    }
  }

  void _onSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (trimmed != _currentQuery || _allPosts.isEmpty) {
      setState(() {
        _currentQuery = trimmed;
        _currentPage = 1;
        _standardPosts = [];
        _allPosts = [];
        _aiPosts = [];
        _allUsers = [];
        _hasMorePosts = false;
        _hasMoreUsers = false;
        _hasError = false;
        _isLoadMoreFailed = false;
      });
      _performSearch();
    }
  }

  void _onSortChanged(SearchSortOrder? order) {
    final currentOrder = ref.read(searchSettingsProvider).sortOrder;
    if (order != null && order != currentOrder) {
      ref.read(searchSettingsProvider.notifier).setSortOrder(order);
      setState(() {
        _currentPage = 1;
        _standardPosts = [];
        _allPosts = [];
        _allUsers = [];
        // 切换排序时清空 AI 结果
        _aiPosts = [];
        _isSearchingAi = false;
      });
      _performSearch();
    }
  }

  void _onFilterChanged(SearchFilter newFilter) {
    setState(() {
      _filter = newFilter;
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _openFilterPanel() {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SearchFilterPanel(
          filter: _filter,
          onFilterChanged: _onFilterChanged,
          hideInType: true,
        ),
      ),
    );
  }

  /// 从查询字符串中移除 order:xxx 部分，返回纯净的查询
  String _stripOrderFromQuery(String query) {
    return query
        .replaceAll(
          RegExp(r'\s*order:(relevance|latest|likes|views|latest_topic)\s*'),
          ' ',
        )
        .trim();
  }

  /// 从查询字符串中提取排序方式
  SearchSortOrder? _extractOrderFromQuery(String query) {
    final match = RegExp(
      r'order:(relevance|latest|likes|views|latest_topic)',
    ).firstMatch(query);
    if (match == null) return null;
    final orderValue = match.group(1);
    return SearchSortOrder.values.firstWhere(
      (e) => e.value == orderValue,
      orElse: () => SearchSortOrder.relevance,
    );
  }

  /// RRF（Reciprocal Rank Fusion）算法，与 Discourse 前端一致
  /// 将标准搜索结果和 AI 搜索结果按倒数排名融合
  List<SearchPost> _mergeWithRRF(
    List<SearchPost> standard,
    List<SearchPost> ai,
  ) {
    if (ai.isEmpty) return standard;
    if (standard.isEmpty) return ai;

    const k = 5; // RRF 常数，与 Discourse 一致

    // 为每个结果计算 RRF 分数，key 为 topic_id
    final scoreMap = <int, double>{};
    final postMap = <int, SearchPost>{};

    for (var i = 0; i < standard.length; i++) {
      final topicId = standard[i].topic?.id;
      if (topicId == null) continue;
      scoreMap[topicId] = 1.0 / (i + k);
      postMap[topicId] = standard[i];
    }

    for (var i = 0; i < ai.length; i++) {
      final topicId = ai[i].topic?.id;
      if (topicId == null) continue;
      if (scoreMap.containsKey(topicId)) {
        // 两个列表都有的结果，分数累加（排名更靠前）
        scoreMap[topicId] = scoreMap[topicId]! + 1.0 / (i + k);
      } else {
        scoreMap[topicId] = 1.0 / (i + k);
        postMap[topicId] = ai[i];
      }
    }

    // 按 RRF 分数降序排列
    final sortedIds = scoreMap.keys.toList()
      ..sort((a, b) => scoreMap[b]!.compareTo(scoreMap[a]!));

    return sortedIds.map((id) => postMap[id]!).toList();
  }

  /// 根据当前 AI 开关状态重新构建展示列表
  void _rebuildDisplayPosts() {
    final settings = ref.read(searchSettingsProvider);
    final showAi =
        _siteAiSearchAvailable &&
        settings.aiSearchEnabled &&
        settings.sortOrder == SearchSortOrder.relevance &&
        _aiPosts.isNotEmpty;

    if (showAi) {
      _allPosts = _mergeWithRRF(_standardPosts, _aiPosts);
    } else {
      _allPosts = List.of(_standardPosts);
    }
  }

  bool _shouldTriggerAiSearch() {
    final sortOrder = ref.read(searchSettingsProvider).sortOrder;
    final aiEnabled = ref.read(searchSettingsProvider).aiSearchEnabled;
    return _siteAiSearchAvailable &&
        aiEnabled &&
        sortOrder == SearchSortOrder.relevance;
  }

  void _triggerAiSearch(String query) async {
    setState(() => _isSearchingAi = true);
    try {
      final service = ref.read(discourseServiceProvider);
      final aiResult = await service.semanticSearch(query: query);
      if (!mounted) return;

      // 标记为 AI 生成
      _aiPosts = aiResult.posts
          .map((p) => p.copyWith(isAiGenerated: true))
          .toList();

      setState(() {
        _isSearchingAi = false;
        _rebuildDisplayPosts();
      });
    } catch (e) {
      // 静默失败，404/403/429 都不影响标准搜索
      if (mounted) setState(() => _isSearchingAi = false);
    }
  }

  Future<void> _performSearch() async {
    if (_currentQuery.isEmpty) return;

    final isLoadMore = _currentPage > 1;

    setState(() {
      _hasError = false;
      _isLoadMoreFailed = false;
      if (!isLoadMore) {
        _isLoadingMore = false;
      }
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final sortOrder = ref.read(searchSettingsProvider).sortOrder;

      // 构建查询字符串
      final cleanQuery = _stripOrderFromQuery(_currentQuery);
      String searchQuery = cleanQuery;

      // 添加过滤条件
      final filterQuery = _filter.toQueryString();
      if (filterQuery.isNotEmpty) {
        searchQuery = '$searchQuery $filterQuery';
      }

      // 添加排序
      if (sortOrder.value != null) {
        searchQuery = '$searchQuery order:${sortOrder.value}';
      }

      // 首页搜索时并行触发 AI 语义搜索
      if (_currentPage == 1 && _shouldTriggerAiSearch()) {
        _triggerAiSearch(cleanQuery);
      }

      final result = await service.search(
        query: searchQuery,
        page: _currentPage,
        typeFilter: 'topic',
      );

      setState(() {
        if (_currentPage == 1) {
          _standardPosts = result.posts;
          _allUsers = result.users;
        } else {
          _standardPosts.addAll(result.posts);
        }
        _hasMorePosts = result.hasMorePosts;
        _hasMoreUsers = result.hasMoreUsers;
        _isLoadingMore = false;
        _rebuildDisplayPosts();
      });
    } catch (e) {
      setState(() {
        _isLoadingMore = false;
        if (isLoadMore) {
          // 加载更多失败：回退页码，显示重试
          _currentPage--;
          _isLoadMoreFailed = true;
        } else {
          // 首次搜索失败：显示全局错误
          _hasError = true;
          _errorMessage = e.toString();
        }
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMorePosts || _isLoadMoreFailed) return;

    setState(() {
      _isLoadingMore = true;
      _currentPage++;
    });

    await _performSearch();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _currentQuery = '';
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
      _isSearchingAi = false;
      _hasMorePosts = false;
      _hasMoreUsers = false;
      _currentPage = 1;
    });
    _focusNode.requestFocus();
  }

  void _clearCategory() {
    setState(() {
      _filter = _filter.copyWith(clearCategory: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _filter = _filter.copyWith(
        tags: _filter.tags.where((t) => t != tag).toList(),
      );
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearStatus() {
    setState(() {
      _filter = _filter.copyWith(clearStatus: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearDateRange() {
    setState(() {
      _filter = _filter.copyWith(clearDateRange: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearAllFilters() {
    setState(() {
      _filter = _filter.clear();
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onSubmitted: _onSearch,
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: context.l10n.search_hintText,
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 12,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _clearSearch,
                  )
                : null,
          ),
          onChanged: (value) {
            setState(() {});
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _onSearch(_searchController.text),
            tooltip: context.l10n.common_search,
          ),
          // 过滤器按钮
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.tune),
                onPressed: _openFilterPanel,
                tooltip: context.l10n.search_advancedSearch,
              ),
              if (_filter.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 已激活的过滤条件（始终显示，便于查看和取消）
          if (_filter.isNotEmpty)
            ActiveSearchFiltersBar(
              filter: _filter,
              onClearCategory: _clearCategory,
              onRemoveTag: _removeTag,
              onClearStatus: _clearStatus,
              onClearDateRange: _clearDateRange,
              onClearAll: _clearAllFilters,
            ),
          Expanded(
            child: _currentQuery.isEmpty
                ? _buildEmptyState(theme)
                : _buildSearchResults(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    // 正在加载最近搜索记录
    if (_isLoadingRecentSearches) {
      return const Center(child: LoadingSpinner());
    }

    // 有最近搜索记录时显示记录列表
    if (_recentSearches.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 最近搜索标题行
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  context.l10n.search_recentSearches,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                GestureDetector(
                  onTap: _isClearingRecentSearches
                      ? null
                      : _clearRecentSearches,
                  child: _isClearingRecentSearches
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Text(
                          context.l10n.common_clear,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                ),
              ],
            ),
          ),
          // 搜索记录列表
          ..._recentSearches.map(
            (query) => _buildRecentSearchItem(query, theme),
          ),
        ],
      );
    }

    // 默认空状态
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            context.l10n.search_emptyHint,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建最近搜索项
  Widget _buildRecentSearchItem(String query, ThemeData theme) {
    // 提取纯净查询
    final cleanQuery = _stripOrderFromQuery(query);

    return InkWell(
      onTap: () {
        // 如果历史记录中有排序设置，恢复它
        final extractedOrder = _extractOrderFromQuery(query);
        if (extractedOrder != null) {
          ref
              .read(searchSettingsProvider.notifier)
              .setSortOrder(extractedOrder);
        }
        _searchController.text = cleanQuery;
        _onSearch(cleanQuery);
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Icon(
              Icons.history,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                query,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.north_west, size: 16, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    if (_hasError && _allPosts.isEmpty) {
      return _buildError(_errorMessage);
    }

    if (_allPosts.isEmpty && _allUsers.isEmpty && !_isLoadingMore) {
      if (_currentPage == 1) {
        return const Center(child: LoadingSpinner());
      }
      return _buildNoResults();
    }

    return Column(
      children: [
        // 排序选项
        if (_allPosts.isNotEmpty || _allUsers.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  context.l10n.search_sortLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<SearchSortOrder>(
                  value: ref.watch(searchSettingsProvider).sortOrder,
                  isDense: true,
                  underline: const SizedBox(),
                  items: SearchSortOrder.values.map((order) {
                    return DropdownMenuItem(
                      value: order,
                      child: Text(order.label),
                    );
                  }).toList(),
                  onChanged: _onSortChanged,
                ),
                const Spacer(),
                // AI 搜索开关（仅当站点支持时显示）
                if (_siteAiSearchAvailable) ...[
                  if (_isSearchingAi)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.tertiary,
                        ),
                      ),
                    ),
                  Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color:
                        ref.watch(searchSettingsProvider).sortOrder ==
                            SearchSortOrder.relevance
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.outline,
                  ),
                  SizedBox(
                    height: 32,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Switch(
                        value:
                            ref.watch(searchSettingsProvider).aiSearchEnabled &&
                            ref.watch(searchSettingsProvider).sortOrder ==
                                SearchSortOrder.relevance,
                        onChanged:
                            ref.watch(searchSettingsProvider).sortOrder ==
                                SearchSortOrder.relevance
                            ? (value) {
                                ref
                                    .read(searchSettingsProvider.notifier)
                                    .setAiSearchEnabled(value);
                                setState(() {
                                  _rebuildDisplayPosts();
                                  // 开启时若还没有 AI 结果，触发搜索
                                  if (value &&
                                      _aiPosts.isEmpty &&
                                      _currentQuery.isNotEmpty) {
                                    final cleanQuery = _stripOrderFromQuery(
                                      _currentQuery,
                                    );
                                    _triggerAiSearch(cleanQuery);
                                  }
                                });
                              }
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  context.l10n.search_resultCount(
                    _allPosts.length,
                    _hasMorePosts ? '+' : '',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount:
                _allPosts.length +
                (_allUsers.isNotEmpty ? _allUsers.length + 1 : 0) +
                (_isLoadingMore || _isLoadMoreFailed ? 1 : 0),
            itemBuilder: (context, index) {
              // 帖子结果（标准 + AI 混合）
              if (index < _allPosts.length) {
                final searchPost = _allPosts[index];
                final enableLongPress = ref
                    .watch(preferencesProvider)
                    .longPressPreview;
                return SearchPostCard(
                  post: searchPost,
                  onTap: () {
                    final topic = searchPost.topic;
                    if (topic != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TopicDetailPage(
                            topicId: topic.id,
                            scrollToPostNumber: searchPost.postNumber,
                          ),
                        ),
                      );
                    }
                  },
                  onLongPress: enableLongPress
                      ? () => SearchPreviewDialog.show(
                          context,
                          post: searchPost,
                          onOpen: () {
                            final topic = searchPost.topic;
                            if (topic != null) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TopicDetailPage(
                                    topicId: topic.id,
                                    scrollToPostNumber: searchPost.postNumber,
                                  ),
                                ),
                              );
                            }
                          },
                        )
                      : null,
                );
              }

              // 用户标题
              final userStartIndex = _allPosts.length;
              if (_allUsers.isNotEmpty && index == userStartIndex) {
                return Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: _buildSectionHeader(
                    context.l10n.search_users,
                    _allUsers.length,
                    _hasMoreUsers,
                  ),
                );
              }

              // 用户结果
              if (_allUsers.isNotEmpty && index > userStartIndex) {
                final userIndex = index - userStartIndex - 1;
                if (userIndex < _allUsers.length) {
                  return _SearchUserCard(
                    user: _allUsers[userIndex],
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserProfilePage(
                            username: _allUsers[userIndex].username,
                          ),
                        ),
                      );
                    },
                  );
                }
              }

              // 加载更多失败重试
              if (_isLoadMoreFailed) {
                return Padding(
                  padding: const EdgeInsets.all(16),
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

              // 加载更多指示器
              if (_isLoadingMore) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: LoadingSpinner()),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildError(String error) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(context.l10n.search_error, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildNoResults() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            context.l10n.search_noResults,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.search_tryOtherKeywords,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, bool hasMore) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          hasMore ? '$count+' : '$count',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

/// 搜索结果用户卡片
class _SearchUserCard extends StatelessWidget {
  final SearchUser user;
  final VoidCallback? onTap;

  const _SearchUserCard({required this.user, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SmartAvatar(
                imageUrl: user.getAvatarUrl().isNotEmpty
                    ? user.getAvatarUrl(size: 80)
                    : null,
                radius: 20,
                fallbackText: user.username,
                backgroundColor: theme.colorScheme.secondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.username,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (user.name != null && user.name!.isNotEmpty)
                      Text(
                        user.name!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
