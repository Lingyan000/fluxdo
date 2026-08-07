import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/user_content_search_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/master_detail_pane_host.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
import '../widgets/topic/topic_card_prewarmer.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/error_view.dart';
import '../l10n/s.dart';
import '../widgets/desktop_refresh_indicator.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 我的话题页面
class MyTopicsPage extends ConsumerStatefulWidget {
  const MyTopicsPage({super.key});

  @override
  ConsumerState<MyTopicsPage> createState() => _MyTopicsPageState();
}

class _MyTopicsPageState extends ConsumerState<MyTopicsPage> {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();
  late final UserContentSearchNotifier _searchNotifier;

  /// 在 build 里取（不能在点击回调里读 MediaQuery）
  bool _canShowBothPanes = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchNotifier = ref.read(
      userContentSearchProvider(SearchInType.created).notifier,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // 延迟清理搜索状态，避免在 widget tree finalizing 期间修改 provider
    Future(_searchNotifier.exitSearchMode);
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
    final notifier = ref.read(myTopicsProvider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () => ref.read(myTopicsProvider).value?.length ?? 0,
    );
  }

  Future<void> _onRefresh() async {
    _loadMoreCoordinator.resetCooldown();
    await ref.read(myTopicsProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
    // 宽屏进右栏,窄屏全屏 push——与草稿页同一套形态
    if (_canShowBothPanes) {
      ref.read(selectedMyTopicsPaneProvider.notifier).select(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: topic.lastReadPostNumber,
          );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myTopicsAsync = ref.watch(myTopicsProvider);
    final searchState = ref.watch(
      userContentSearchProvider(SearchInType.created),
    );
    // 话题卡自定义样式:改设置触发 rebuild(自绘排版直读全局快照)
    ref.watch(preferencesProvider.select((p) => p.topicCardStyle));
    _canShowBothPanes = MasterDetailLayout.canShowBothPanesFor(context);

    final list = PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // 搜索模式下按返回键，退出搜索而不是退出页面
          ref
              .read(userContentSearchProvider(SearchInType.created).notifier)
              .exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: context.l10n.myTopics_title,
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(userContentSearchProvider(SearchInType.created).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(userContentSearchProvider(SearchInType.created).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(userContentSearchProvider(SearchInType.created).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, SearchInType.created),
          searchHint: context.l10n.myTopics_searchHint,
        ),
        body: Stack(
          children: [
            // 使用 Offstage 保持列表存在但在搜索模式下隐藏，保留滚动位置
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(myTopicsAsync),
            ),
            if (searchState.isSearchMode)
              UserContentSearchView(
                inType: SearchInType.created,
                emptySearchHint: context.l10n.myTopics_emptySearchHint,
              ),
          ],
        ),
      ),
    );

    return MasterDetailPaneHost(
      stackProvider: selectedMyTopicsPaneProvider,
      master: list,
    );
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> myTopicsAsync) {
    final selectedTopicId = ref.watch(
      selectedMyTopicsPaneProvider.select((s) => s.topicId),
    );
    return DesktopRefreshIndicator(
      onRefresh: _onRefresh,
      child: myTopicsAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Symbols.article_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.myTopics_empty,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return TopicCardPrewarmScope(
            topics: topics,
            child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + 1,
            itemBuilder: (context, index) {
              if (index == topics.length) {
                final notifier = ref.watch(myTopicsProvider.notifier);
                return PagedListFooter(
                  hasMore: notifier.hasMore,
                  isLoadingMore: notifier.isLoadingMore,
                  isLoadMoreFailed: notifier.isLoadMoreFailed,
                  onRetry: notifier.retryLoadMore,
                );
              }

              final topic = topics[index];
              final enableLongPress = ref
                  .watch(preferencesProvider)
                  .longPressPreview;
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: _canShowBothPanes && topic.id == selectedTopicId,
                onTap: () => _onItemTap(topic),
                enableLongPress: enableLongPress,
              );
            },
            ),
          );
        },
        loading: () => const TopicListSkeleton(),
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: _onRefresh),
      ),
    );
  }
}
