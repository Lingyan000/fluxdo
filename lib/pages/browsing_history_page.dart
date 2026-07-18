import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../models/topic.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/discourse_providers.dart';
import '../providers/user_content_search_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/blocked_user_filter.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/error_view.dart';
import '../l10n/s.dart';
import '../widgets/desktop_refresh_indicator.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 浏览历史页面
class BrowsingHistoryPage extends ConsumerStatefulWidget {
  const BrowsingHistoryPage({super.key, this.isActive = true});

  /// 是否为当前活跃的 tab（嵌入底栏时用于决定是否响应 NavActionBus）
  final bool isActive;

  @override
  ConsumerState<BrowsingHistoryPage> createState() =>
      _BrowsingHistoryPageState();
}

class _BrowsingHistoryPageState extends ConsumerState<BrowsingHistoryPage> {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();
  late final UserContentSearchNotifier _searchNotifier;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchNotifier = ref.read(
      userContentSearchProvider(SearchInType.seen).notifier,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    Future(_searchNotifier.exitSearchMode);
    super.dispose();
  }

  void _onScroll() {
    _publishScrollProgress();
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(browsingHistoryProvider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () => ref.read(browsingHistoryProvider).value?.length ?? 0,
    );
  }

  void _publishScrollProgress() {
    if (!_scrollController.hasClients) return;
    final raw = _scrollController.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.history));
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.history).notifier).state =
        progress;
  }

  Future<void> _onRefresh() async {
    _loadMoreCoordinator.resetCooldown();
    await ref.read(browsingHistoryProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
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
    final historyAsync = ref.watch(browsingHistoryProvider);
    final searchState = ref.watch(userContentSearchProvider(SearchInType.seen));

    // 嵌入底栏时响应快捷动作（仅活跃 tab 响应）
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null || event.targetId != NavEntryIds.history) return;
      if (!widget.isActive) return;
      switch (event.action) {
        case NavAction.scrollToTop:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case NavAction.refresh:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _onRefresh();
          ref.resetNavScrollProgress(NavEntryIds.history);
          break;
      }
    });

    return PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // 搜索模式下按返回键，退出搜索而不是退出页面
          ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: context.l10n.browsingHistory_title,
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, SearchInType.seen),
          searchHint: context.l10n.browsingHistory_searchHint,
        ),
        body: Stack(
          children: [
            // 使用 Offstage 保持列表存在但在搜索模式下隐藏，保留滚动位置
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(historyAsync),
            ),
            if (searchState.isSearchMode)
              UserContentSearchView(
                inType: SearchInType.seen,
                emptySearchHint: context.l10n.browsingHistory_emptySearchHint,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> historyAsync) {
    return DesktopRefreshIndicator(
      onRefresh: _onRefresh,
      child: historyAsync.when(
        data: (topics) {
          final blockedUsernames = ref.watch(
            preferencesProvider.select((p) => p.normalizedBlockedUsernames),
          );
          // 话题卡自定义样式:改设置触发 rebuild(自绘排版直读全局快照)
          ref.watch(preferencesProvider.select((p) => p.topicCardStyle));
          final visibleTopics = BlockedUserFilter.visibleTopics(
            topics,
            blockedUsernames,
          );
          final notifier = ref.read(browsingHistoryProvider.notifier);
          // 已加载页全部被本地屏蔽时列表不可滚，滚动触发的翻页永远不会发生；
          // 主动补载下一页（coordinator 自带冷却，不会打转），footer 显示加载中
          if (visibleTopics.isEmpty && topics.isNotEmpty && notifier.hasMore) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadMore();
            });
          }
          if (visibleTopics.isEmpty && (topics.isEmpty || !notifier.hasMore)) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Symbols.history_rounded, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.browsingHistory_empty,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            // 底部让出 extendBody 注入的底栏高度
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: visibleTopics.length + 1,
            itemBuilder: (context, index) {
              if (index == visibleTopics.length) {
                final notifier = ref.watch(browsingHistoryProvider.notifier);
                return PagedListFooter(
                  hasMore: notifier.hasMore,
                  isLoadingMore: notifier.isLoadingMore,
                  isLoadMoreFailed: notifier.isLoadMoreFailed,
                  onRetry: notifier.retryLoadMore,
                );
              }

              final topic = visibleTopics[index];
              final enableLongPress = ref
                  .watch(preferencesProvider)
                  .longPressPreview;
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: false,
                onTap: () => _onItemTap(topic),
                enableLongPress: enableLongPress,
              );
            },
          );
        },
        loading: () => const TopicListSkeleton(),
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: _onRefresh),
      ),
    );
  }
}
