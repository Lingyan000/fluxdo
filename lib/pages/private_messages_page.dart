import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../providers/user_content_providers.dart';
import '../providers/preferences_provider.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/common/error_view.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../l10n/s.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 私信列表页面
class PrivateMessagesPage extends ConsumerStatefulWidget {
  const PrivateMessagesPage({super.key});

  @override
  ConsumerState<PrivateMessagesPage> createState() =>
      _PrivateMessagesPageState();
}

class _PrivateMessagesPageState extends ConsumerState<PrivateMessagesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _filters = [
    PrivateMessageFilter.inbox,
    PrivateMessageFilter.sent,
    PrivateMessageFilter.archive,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.privateMessages_title),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: context.l10n.privateMessages_inbox),
            Tab(text: context.l10n.privateMessages_sent),
            Tab(text: context.l10n.privateMessages_archive),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final filter in _filters)
            _PrivateMessageTabView(filter: filter),
        ],
      ),
    );
  }
}

/// 单个 Tab 的私信列表视图
class _PrivateMessageTabView extends ConsumerStatefulWidget {
  final PrivateMessageFilter filter;

  const _PrivateMessageTabView({required this.filter});

  @override
  ConsumerState<_PrivateMessageTabView> createState() =>
      _PrivateMessageTabViewState();
}

class _PrivateMessageTabViewState
    extends ConsumerState<_PrivateMessageTabView>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

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

  /// 获取当前 tab 对应的数据和 notifier
  (AsyncValue<List<Topic>>, PrivateMessagesNotifier) _watchMessages() {
    return switch (widget.filter) {
      PrivateMessageFilter.inbox => (
          ref.watch(pmInboxProvider),
          ref.watch(pmInboxProvider.notifier),
        ),
      PrivateMessageFilter.sent => (
          ref.watch(pmSentProvider),
          ref.watch(pmSentProvider.notifier),
        ),
      PrivateMessageFilter.archive => (
          ref.watch(pmArchiveProvider),
          ref.watch(pmArchiveProvider.notifier),
        ),
    };
  }

  PrivateMessagesNotifier _readNotifier() {
    return switch (widget.filter) {
      PrivateMessageFilter.inbox => ref.read(pmInboxProvider.notifier),
      PrivateMessageFilter.sent => ref.read(pmSentProvider.notifier),
      PrivateMessageFilter.archive => ref.read(pmArchiveProvider.notifier),
    };
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _readNotifier().loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await _readNotifier().refresh();
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
    super.build(context);
    final (messagesAsync, notifier) = _watchMessages();

    return DesktopRefreshIndicator(
      onRefresh: _onRefresh,
      child: messagesAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mail_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.privateMessages_empty,
                    style: const TextStyle(color: Colors.grey),
                  ),
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
                return _buildPaginationFooter(messagesAsync, notifier);
              }

              final topic = topics[index];
              final enableLongPress =
                  ref.watch(preferencesProvider).longPressPreview;
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
        error: (error, stack) => ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: _onRefresh,
        ),
      ),
    );
  }

  Widget _buildPaginationFooter(
    AsyncValue<List<Topic>> messagesAsync,
    PrivateMessagesNotifier notifier,
  ) {
    if (!notifier.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Text(
            context.l10n.common_noMore,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (notifier.isLoadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: GestureDetector(
            onTap: () => notifier.retryLoadMore(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  context.l10n.common_loadFailedTapRetry,
                  style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (messagesAsync.isLoading && !messagesAsync.hasError) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const SizedBox();
  }
}
