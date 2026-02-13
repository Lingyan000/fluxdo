import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/preferences_provider.dart';
import '../utils/pagination_helper.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/sort_and_tags_bar.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_notification_button.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../widgets/common/error_view.dart';
import '../widgets/layout/master_detail_layout.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import 'create_topic_page.dart';

/// 分类话题列表页面（独立页面，不影响首页筛选）
class CategoryTopicsPage extends ConsumerStatefulWidget {
  final Category category;

  const CategoryTopicsPage({super.key, required this.category});

  @override
  ConsumerState<CategoryTopicsPage> createState() => _CategoryTopicsPageState();
}

class _CategoryTopicsPageState extends ConsumerState<CategoryTopicsPage> {
  final ScrollController _scrollController = ScrollController();
  List<Topic> _topics = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  Object? _error;
  String? _parentSlug;

  // 本地排序和标签状态（独立于首页）
  TopicListFilter _currentSort = TopicListFilter.latest;
  List<String> _selectedTags = [];

  static final _paginationHelper = PaginationHelpers.forTopics<Topic>(
    keyExtractor: (topic) => topic.id,
  );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _resolveParentSlug();
    _loadTopics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _resolveParentSlug() {
    if (widget.category.parentCategoryId != null) {
      final categoryMap = ref.read(categoryMapProvider).value;
      if (categoryMap != null) {
        _parentSlug = categoryMap[widget.category.parentCategoryId]?.slug;
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
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
        filter: _currentSort.filterName,
        categoryId: widget.category.id,
        categorySlug: widget.category.slug,
        parentCategorySlug: _parentSlug,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
        page: 0,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
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
        filter: _currentSort.filterName,
        categoryId: widget.category.id,
        categorySlug: widget.category.slug,
        parentCategorySlug: _parentSlug,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
        page: 0,
      );

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );

      if (mounted) {
        setState(() {
          _topics = result.items;
          _hasMore = result.hasMore;
          _page = 0;
        });
      }
    } catch (e) {
      debugPrint('[CategoryTopics] 刷新失败: $e');
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoadingMore || _isLoading) return;

    setState(() => _isLoadingMore = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final nextPage = _page + 1;
      final response = await service.getFilteredTopics(
        filter: _currentSort.filterName,
        categoryId: widget.category.id,
        categorySlug: widget.category.slug,
        parentCategorySlug: _parentSlug,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
        page: nextPage,
      );

      final currentState = PaginationState(items: _topics);
      final result = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
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
        setState(() => _isLoadingMore = false);
      }
    }
  }

  void _setSort(TopicListFilter sort) {
    if (sort == _currentSort) return;
    setState(() => _currentSort = sort);
    _loadTopics();
  }

  void _removeTag(String tag) {
    setState(() => _selectedTags = _selectedTags.where((t) => t != tag).toList());
    _loadTopics();
  }

  Future<void> _setCategoryNotificationLevel(CategoryNotificationLevel level) async {
    final overrides = ref.read(categoryNotificationOverridesProvider);
    final oldLevel = overrides[widget.category.id] ?? widget.category.notificationLevel;
    // 乐观更新
    ref.read(categoryNotificationOverridesProvider.notifier).set({
      ...overrides,
      widget.category.id: level.value,
    });
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setCategoryNotificationLevel(widget.category.id, level.value);
    } catch (_) {
      // 失败时回退
      if (mounted) {
        final current = ref.read(categoryNotificationOverridesProvider);
        if (oldLevel != null) {
          ref.read(categoryNotificationOverridesProvider.notifier).set({
            ...current,
            widget.category.id: oldLevel,
          });
        } else {
          ref.read(categoryNotificationOverridesProvider.notifier).set(
              Map.from(current)..remove(widget.category.id),
          );
        }
      }
    }
  }

  Future<void> _openTagSelection() async {
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
        categoryId: widget.category.id,
        availableTags: availableTags,
        selectedTags: _selectedTags,
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      setState(() => _selectedTags = result);
      _loadTopics();
    }
  }

  Future<void> _createTopic() async {
    final topicId = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => CreateTopicPage(
        initialCategoryId: widget.category.id,
        initialTags: _selectedTags.isNotEmpty ? _selectedTags : null,
      )),
    );
    if (topicId != null && mounted) {
      _silentRefresh();
    }
  }

  Future<void> _openTopic(Topic topic) async {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref.read(selectedTopicProvider.notifier).select(
        topicId: topic.id,
        initialTitle: topic.title,
        scrollToPostNumber: topic.lastReadPostNumber,
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );

    // 从话题详情返回后，静默刷新以获取 MessageBus 更新的状态
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
        title: Text(widget.category.name),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SearchPage(
                initialFilter: SearchFilter(
                  categoryId: widget.category.id,
                  categorySlug: widget.category.slug,
                  categoryName: widget.category.name,
                  parentCategorySlug: _parentSlug,
                ),
              )),
            ),
            tooltip: '搜索',
          ),
        ],
      ),
      body: Column(
        children: [
          // 排序 + 标签栏
          SortAndTagsBar(
            currentSort: _currentSort,
            isLoggedIn: isLoggedIn,
            onSortChanged: _setSort,
            selectedTags: _selectedTags,
            onTagRemoved: _removeTag,
            onAddTag: _openTagSelection,
            trailing: isLoggedIn
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CreateTopicButton(onPressed: _createTopic),
                      const SizedBox(width: 6),
                      Builder(builder: (context) {
                        final overrides = ref.watch(categoryNotificationOverridesProvider);
                        final effectiveLevel = overrides[widget.category.id]
                            ?? widget.category.notificationLevel;
                        return CategoryNotificationButton(
                          level: CategoryNotificationLevel.fromValue(effectiveLevel),
                          onChanged: _setCategoryNotificationLevel,
                        );
                      }),
                    ],
                  )
                : null,
          ),
          // 列表
          Expanded(child: _buildBody(selectedTopicId)),
        ],
      ),
    );
  }

  Widget _buildBody(int? selectedTopicId) {
    if (_isLoading) {
      return const TopicListSkeleton(
        padding: EdgeInsets.all(12),
      );
    }

    if (_error != null) {
      return ErrorView(
        error: _error!,
        onRetry: _loadTopics,
      );
    }

    if (_topics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('该分类下暂无话题'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTopics,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: _topics.length + 1,
        itemBuilder: (context, index) {
          if (index >= _topics.length) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: _hasMore
                    ? const CircularProgressIndicator()
                    : const Text('没有更多了', style: TextStyle(color: Colors.grey)),
              ),
            );
          }

          final topic = _topics[index];
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
    );
  }
}

/// 创建话题快捷按钮（紧凑 chip 样式）
class _CreateTopicButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CreateTopicButton({required this.onPressed});

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
              Icon(Icons.edit_outlined, size: 14, color: fgColor),
              const SizedBox(width: 4),
              Text(
                '发帖',
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
