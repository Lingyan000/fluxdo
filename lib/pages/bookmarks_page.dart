import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../providers/discourse_providers.dart';
import '../widgets/topic/paginated_topic_list_page.dart';

/// 我的书签页面
class BookmarksPage extends ConsumerWidget {
  const BookmarksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PaginatedTopicListPage(
      title: '我的书签',
      provider: bookmarksProvider,
      searchInType: SearchInType.bookmarks,
      emptyIcon: Icons.bookmark_border,
      emptyText: '暂无书签',
      searchHint: '在书签中搜索...',
      onLoadMore: () => ref.read(bookmarksProvider.notifier).loadMore(),
      onRefresh: () => ref.read(bookmarksProvider.notifier).refresh(),
      hasMoreGetter: () => ref.read(bookmarksProvider.notifier).hasMore,
    );
  }
}
