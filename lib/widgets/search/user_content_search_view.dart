import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/s.dart';
import '../../models/search_filter.dart';
import '../../providers/user_content_search_provider.dart';
import '../../utils/dialog_utils.dart';
import '../common/loading_spinner.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import 'search_filter_panel.dart';
import 'search_post_card.dart';
import 'search_preview_dialog.dart';
import '../../providers/preferences_provider.dart';

/// 用户内容搜索结果视图
/// 封装通用的搜索结果展示逻辑，避免在各个页面中重复代码
class UserContentSearchView extends ConsumerStatefulWidget {
  /// 搜索范围类型
  final SearchInType inType;

  /// 空搜索状态的提示文字
  final String emptySearchHint;

  /// 自定义打开话题行为（如桌面工作区复用标签）
  final void Function({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
  })? onOpenTopic;

  const UserContentSearchView({
    super.key,
    required this.inType,
    required this.emptySearchHint,
    this.onOpenTopic,
  });

  @override
  ConsumerState<UserContentSearchView> createState() =>
      _UserContentSearchViewState();
}

class _UserContentSearchViewState extends ConsumerState<UserContentSearchView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(userContentSearchProvider(widget.inType).notifier).loadMore();
    }
  }

  void _onClearCategory() {
    final notifier = ref.read(userContentSearchProvider(widget.inType).notifier);
    notifier.setCategory();
    _refreshIfHasQuery();
  }

  void _onRemoveTag(String tag) {
    final notifier = ref.read(userContentSearchProvider(widget.inType).notifier);
    notifier.removeTag(tag);
    _refreshIfHasQuery();
  }

  void _onClearStatus() {
    final notifier = ref.read(userContentSearchProvider(widget.inType).notifier);
    notifier.setStatus(null);
    _refreshIfHasQuery();
  }

  void _onClearDateRange() {
    final notifier = ref.read(userContentSearchProvider(widget.inType).notifier);
    notifier.setDateRange();
    _refreshIfHasQuery();
  }

  void _onClearAll() {
    final notifier = ref.read(userContentSearchProvider(widget.inType).notifier);
    notifier.clearFilters();
    _refreshIfHasQuery();
  }

  void _refreshIfHasQuery() {
    final state = ref.read(userContentSearchProvider(widget.inType));
    if (state.query.isNotEmpty) {
      ref
          .read(userContentSearchProvider(widget.inType).notifier)
          .refreshWithCurrentFilters();
    }
  }

  void _openTopic({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
  }) {
    final customHandler = widget.onOpenTopic;
    if (customHandler != null) {
      customHandler(
        topicId: topicId,
        title: title,
        scrollToPostNumber: scrollToPostNumber,
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          initialTitle: title,
          scrollToPostNumber: scrollToPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchState = ref.watch(userContentSearchProvider(widget.inType));

    // 显示过滤条件
    Widget? filterBar;
    if (searchState.filter.isNotEmpty) {
      filterBar = ActiveSearchFiltersBar(
        filter: searchState.filter,
        onClearCategory: _onClearCategory,
        onRemoveTag: _onRemoveTag,
        onClearStatus: _onClearStatus,
        onClearDateRange: _onClearDateRange,
        onClearAll: _onClearAll,
      );
    }
    final filterWidgets = filterBar == null ? const <Widget>[] : <Widget>[filterBar];

    // 未搜索状态
    if (searchState.query.isEmpty && searchState.results.isEmpty) {
      return Column(
        children: [
          ...filterWidgets,
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search, size: 64, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    widget.emptySearchHint,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // 加载中（首次搜索）
    if (searchState.isLoading && searchState.results.isEmpty) {
      return Column(
        children: [
          ...filterWidgets,
          const Expanded(child: Center(child: LoadingSpinner())),
        ],
      );
    }

    // 错误状态
    if (searchState.error != null && searchState.results.isEmpty) {
      return Column(
        children: [
          ...filterWidgets,
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(context.l10n.search_error, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    searchState.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // 无结果
    if (searchState.results.isEmpty) {
      return Column(
        children: [
          ...filterWidgets,
          Expanded(
            child: Center(
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
            ),
          ),
        ],
      );
    }

    // 搜索结果
    return Column(
      children: [
        ...filterWidgets,
        // 结果数量
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                context.l10n.search_resultCount(searchState.results.length, searchState.hasMore ? '+' : ''),
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
            itemCount: searchState.results.length + (searchState.isLoading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == searchState.results.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: LoadingSpinner()),
                );
              }

              final post = searchState.results[index];
              final enableLongPress = ref.watch(preferencesProvider).longPressPreview;
              return SearchPostCard(
                post: post,
                onTap: () {
                  final topic = post.topic;
                  if (topic != null) {
                    _openTopic(
                      topicId: topic.id,
                      title: topic.title,
                      scrollToPostNumber: post.postNumber,
                    );
                  }
                },
                onLongPress: enableLongPress
                    ? () => SearchPreviewDialog.show(
                          context,
                          post: post,
                          onOpen: () {
                            final topic = post.topic;
                            if (topic != null) {
                              _openTopic(
                                topicId: topic.id,
                                title: topic.title,
                                scrollToPostNumber: post.postNumber,
                              );
                            }
                          },
                        )
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 打开搜索过滤器面板的便捷方法
void showSearchFilterPanel(
  BuildContext context,
  WidgetRef ref,
  SearchInType inType,
) {
  final searchState = ref.read(userContentSearchProvider(inType));
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
        filter: searchState.filter,
        onFilterChanged: (newFilter) {
          final notifier = ref.read(userContentSearchProvider(inType).notifier);
          notifier.setTags(newFilter.tags);
          if (newFilter.categoryId != null) {
            notifier.setCategory(
              categoryId: newFilter.categoryId,
              categorySlug: newFilter.categorySlug,
              categoryName: newFilter.categoryName,
              parentCategorySlug: newFilter.parentCategorySlug,
            );
          } else {
            notifier.setCategory();
          }
          notifier.setStatus(newFilter.status);
          notifier.setDateRange(
            after: newFilter.afterDate,
            before: newFilter.beforeDate,
          );
          // 如果有搜索词，重新搜索
          if (searchState.query.isNotEmpty) {
            notifier.refreshWithCurrentFilters();
          }
        },
      ),
    ),
  );
}
