import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/s.dart';
import '../../providers/topic_search_provider.dart';
import '../../utils/load_more_coordinator.dart';
import '../common/paged_list_footer.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../providers/selected_topic_provider.dart';
import 'search_list_skeleton.dart';
import 'search_post_card.dart';
import 'search_preview_dialog.dart';
import '../../providers/preferences_provider.dart';
import '../topic/topic_preview_dialog.dart' show topicCardAnchorRect;

/// 话题内搜索结果视图
class TopicSearchView extends ConsumerStatefulWidget {
  /// 话题 ID
  final int topicId;

  /// 跳转到指定帖子的回调（用于话题内跳转）
  final void Function(int postNumber)? onJumpToPost;

  const TopicSearchView({super.key, required this.topicId, this.onJumpToPost});

  @override
  ConsumerState<TopicSearchView> createState() => _TopicSearchViewState();
}

class _TopicSearchViewState extends ConsumerState<TopicSearchView> {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();

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
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final provider = topicSearchProvider(widget.topicId);
    await _loadMoreCoordinator.loadMore(
      loadMore: ref.read(provider.notifier).loadMore,
      hasMore: () => ref.read(provider).hasMore,
      isActive: () => mounted,
      progressCount: () => ref.read(provider).results.length,
    );
  }

  Future<void> _retryLoadMore() async {
    _loadMoreCoordinator.resetCooldown();
    await ref
        .read(topicSearchProvider(widget.topicId).notifier)
        .retryLoadMore();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchState = ref.watch(topicSearchProvider(widget.topicId));

    // 未搜索状态
    if (searchState.query.isEmpty && searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.search_rounded,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.search_topicSearchHint,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // 加载中（首次搜索）
    if (searchState.isLoading && searchState.results.isEmpty) {
      return const SearchListSkeleton(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      );
    }

    // 错误状态
    if (searchState.error != null && searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.error_rounded,
              size: 48,
              color: theme.colorScheme.error,
            ),
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
      );
    }

    // 无结果
    if (searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.search_off_rounded,
              size: 64,
              color: theme.colorScheme.outline,
            ),
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

    // 搜索结果
    return Column(
      children: [
        // 结果数量
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                context.l10n.search_resultCount(
                  searchState.results.length,
                  searchState.hasMore ? '+' : '',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SearchPostPrewarmScope(
            posts: searchState.results,
            child: ListView.builder(
              controller: _scrollController,
              addAutomaticKeepAlives: false,
              padding: const EdgeInsets.all(16),
              itemCount: searchState.results.length + 1,
              itemBuilder: (context, index) {
                if (index == searchState.results.length) {
                  return PagedListFooter(
                    hasMore: searchState.hasMore,
                    isLoadingMore:
                        searchState.isLoading && searchState.results.isNotEmpty,
                    isLoadMoreFailed: searchState.isLoadMoreFailed,
                    onRetry: _retryLoadMore,
                  );
                }

                final post = searchState.results[index];
                // Builder 紧贴卡片:一镜到底要卡片自身的屏幕 rect 作
                // 起点;bottomGap 8 裁掉外壳底部间距
                final enableLongPress = ref
                    .watch(preferencesProvider)
                    .longPressPreview;
                return Builder(
                  builder: (cardContext) => SearchPostCard(
                    post: post,
                    onTap: () {
                      // 优先使用话题内跳转
                      if (widget.onJumpToPost != null) {
                        widget.onJumpToPost!(post.postNumber);
                      } else {
                        // 跨话题:平行视界面板内压当前栈,全屏页照旧 push
                        final topic = post.topic;
                        if (topic != null) {
                          if (EmbeddedStackScope.maybePushTopic(
                            context,
                            topicId: topic.id,
                            scrollToPostNumber: post.postNumber,
                          )) {
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TopicDetailPage(
                                topicId: topic.id,
                                scrollToPostNumber: post.postNumber,
                              ),
                            ),
                          );
                        }
                      }
                    },
                    onLongPress: enableLongPress
                        ? () => SearchPreviewDialog.show(
                            context,
                            post: post,
                            onOpen: () {
                              if (widget.onJumpToPost != null) {
                                widget.onJumpToPost!(post.postNumber);
                                return;
                              }
                              final topic = post.topic;
                              if (topic != null) {
                                if (EmbeddedStackScope.maybePushTopic(
                                  context,
                                  topicId: topic.id,
                                  scrollToPostNumber: post.postNumber,
                                )) {
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => TopicDetailPage(
                                      topicId: topic.id,
                                      scrollToPostNumber: post.postNumber,
                                    ),
                                  ),
                                );
                              }
                            },
                            anchorRect: topicCardAnchorRect(cardContext),
                          )
                        : null,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
