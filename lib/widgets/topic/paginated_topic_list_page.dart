import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/search_filter.dart';
import '../../models/topic.dart';
import '../../providers/user_content_search_provider.dart';
import '../search/searchable_app_bar.dart';
import '../search/user_content_search_view.dart';
import 'topic_card.dart';
import 'topic_list_skeleton.dart';
import '../common/error_view.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';

/// 通用的分页话题列表页面
///
/// 用于书签、浏览历史、我的话题等结构相同的页面
class PaginatedTopicListPage extends ConsumerStatefulWidget {
  final String title;
  /// The provider to watch for topic list data.
  final dynamic provider;
  final SearchInType searchInType;
  final IconData emptyIcon;
  final String emptyText;
  final String searchHint;
  final VoidCallback onLoadMore;
  final Future<void> Function() onRefresh;
  final bool Function() hasMoreGetter;

  const PaginatedTopicListPage({
    super.key,
    required this.title,
    required this.provider,
    required this.searchInType,
    required this.emptyIcon,
    required this.emptyText,
    required this.searchHint,
    required this.onLoadMore,
    required this.onRefresh,
    required this.hasMoreGetter,
  });

  @override
  ConsumerState<PaginatedTopicListPage> createState() =>
      _PaginatedTopicListPageState();
}

class _PaginatedTopicListPageState
    extends ConsumerState<PaginatedTopicListPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    ref
        .read(userContentSearchProvider(widget.searchInType).notifier)
        .exitSearchMode();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      widget.onLoadMore();
    }
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
    final topicsAsync = ref.watch(widget.provider);
    final searchState =
        ref.watch(userContentSearchProvider(widget.searchInType));

    return PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          ref
              .read(
                  userContentSearchProvider(widget.searchInType).notifier)
              .exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: widget.title,
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(
                  userContentSearchProvider(widget.searchInType).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(
                  userContentSearchProvider(widget.searchInType).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(
                  userContentSearchProvider(widget.searchInType).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, widget.searchInType),
          searchHint: widget.searchHint,
        ),
        body: Stack(
          children: [
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(topicsAsync),
            ),
            if (searchState.isSearchMode)
              UserContentSearchView(
                inType: widget.searchInType,
                emptySearchHint: '输入关键词搜索${widget.title}',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> topicsAsync) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: topicsAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.emptyIcon, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(widget.emptyText,
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + 1,
            itemBuilder: (context, index) {
              if (index == topics.length) {
                if (!widget.hasMoreGetter()) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(
                      child: Text(
                        '没有更多了',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  );
                }
                if (topicsAsync.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return const SizedBox();
              }

              final topic = topics[index];
              return TopicCard(
                topic: topic,
                onTap: () => _onItemTap(topic),
              );
            },
          );
        },
        loading: () => const TopicListSkeleton(),
        error: (error, stack) => ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: widget.onRefresh,
        ),
      ),
    );
  }
}
