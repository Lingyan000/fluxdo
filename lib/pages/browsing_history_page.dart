import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../providers/discourse_providers.dart';
import '../widgets/topic/paginated_topic_list_page.dart';

/// 浏览历史页面
class BrowsingHistoryPage extends ConsumerWidget {
  const BrowsingHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PaginatedTopicListPage(
      title: '浏览历史',
      provider: browsingHistoryProvider,
      searchInType: SearchInType.seen,
      emptyIcon: Icons.history,
      emptyText: '暂无浏览历史',
      searchHint: '在浏览历史中搜索...',
      onLoadMore: () => ref.read(browsingHistoryProvider.notifier).loadMore(),
      onRefresh: () => ref.read(browsingHistoryProvider.notifier).refresh(),
      hasMoreGetter: () => ref.read(browsingHistoryProvider.notifier).hasMore,
    );
  }
}
