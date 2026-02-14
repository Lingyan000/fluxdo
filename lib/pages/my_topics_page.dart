import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../providers/discourse_providers.dart';
import '../widgets/topic/paginated_topic_list_page.dart';

/// 我的话题页面
class MyTopicsPage extends ConsumerWidget {
  const MyTopicsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PaginatedTopicListPage(
      title: '我的话题',
      provider: myTopicsProvider,
      searchInType: SearchInType.created,
      emptyIcon: Icons.article_outlined,
      emptyText: '暂无话题',
      searchHint: '在我的话题中搜索...',
      onLoadMore: () => ref.read(myTopicsProvider.notifier).loadMore(),
      onRefresh: () => ref.read(myTopicsProvider.notifier).refresh(),
      hasMoreGetter: () => ref.read(myTopicsProvider.notifier).hasMore,
    );
  }
}
