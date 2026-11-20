import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/following_feed.dart';
import '../navigation/nav_action_bus.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../providers/core_providers.dart';
import '../providers/following_feed_provider.dart';
import '../providers/following_feed_migration_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/master_detail_pane_host.dart';
import '../widgets/user/activity_card_layout.dart';
import '../widgets/user/activity_post_card.dart';
import '../widgets/user/following_feed_migration_sheet.dart';
import 'follow_list_page.dart';
import 'topic_detail_page/topic_detail_page.dart';

class FollowingFeedPage extends ConsumerStatefulWidget {
  const FollowingFeedPage({super.key, this.isActive = true});
  final bool isActive;
  @override
  ConsumerState<FollowingFeedPage> createState() => _FollowingFeedPageState();
}

class _FollowingFeedPageState extends ConsumerState<FollowingFeedPage> {
  final _scroll = ScrollController();
  final _refreshIndicatorKey = GlobalKey<M3eRefreshIndicatorState>();
  FollowingFeedNotifier? _refreshingNotifier;
  bool _activated = false;
  bool _wide = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh(FollowingFeedNotifier notifier) async {
    setState(() => _refreshingNotifier = notifier);
    try {
      await notifier.refresh();
    } finally {
      if (mounted && _refreshingNotifier == notifier) {
        setState(() => _refreshingNotifier = null);
      }
    }
  }

  Future<void> _showMigrationGuide(String username) async {
    if (!mounted ||
        !widget.isActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        ref.read(currentUserProvider).value?.username != username) {
      return;
    }
    final migration = ref.read(followingFeedMigrationProvider);
    if (!migration.showGuide) return;

    final result = showFollowingFeedMigrationSheet(
      context,
      hasLegacyUsers: migration.users.isNotEmpty,
    );
    // 实际展示后记录，关闭、返回和下滑都结束本次引导。
    await ref.read(followingFeedMigrationProvider.notifier).markSeen();
    if (await result == true &&
        mounted &&
        widget.isActive &&
        ref.read(currentUserProvider).value?.username == username) {
      await showFollowingFeedLegacyUsers(context, migration.users);
    }
  }

  void _openPost(FollowingPost post) {
    if (_wide) {
      ref
          .read(selectedFollowingFeedProvider.notifier)
          .select(
            topicId: post.topicId,
            initialTitle: post.title,
            scrollToPostNumber: post.postNumber,
          );
    } else {
      Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: post.topicId,
            initialTitle: post.title,
            scrollToPostNumber: post.postNumber,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 导航预建的隐藏页面不发请求；访问过后保留列表及滚动位置。
    _activated = _activated || widget.isActive;
    if (!_activated) return const SizedBox.shrink();
    final username = ref.watch(currentUserProvider).value?.username;
    if (username == null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.followingFeed_title)),
        body: Center(child: Text(context.l10n.followingFeed_login)),
      );
    }
    ref.listen(navActionBusProvider, (_, event) {
      if (!widget.isActive ||
          event == null ||
          event.targetId != NavEntryIds.followingFeed) {
        return;
      }
      if (event.action == NavAction.refresh) {
        _refreshIndicatorKey.currentState?.show();
      } else if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
    final state = ref.watch(followingFeedProvider(username));
    final notifier = ref.read(followingFeedProvider(username).notifier);
    final refreshing = _refreshingNotifier == notifier;
    final migration = ref.watch(followingFeedMigrationProvider);
    if (widget.isActive &&
        migration.showGuide &&
        ModalRoute.isCurrentOf(context) == true) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showMigrationGuide(username),
      );
    }
    _wide = MasterDetailLayout.canShowBothPanesFor(context);
    final page = Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.followingFeed_title),
        actions: [
          IconButton(
            tooltip: context.l10n.followingFeed_following,
            icon: const Icon(Symbols.group_rounded),
            onPressed: () => Navigator.of(context).push(
              InteractionPageRoute(
                builder: (_) =>
                    FollowListPage(username: username, isFollowing: true),
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.common_refresh,
            icon: const Icon(Symbols.refresh_rounded),
            onPressed: state.loading
                ? null
                : () => _refreshIndicatorKey.currentState?.show(),
          ),
        ],
      ),
      body: ActivityCardList(
        builder: (context, padding) => NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (widget.isActive &&
                notification.depth == 0 &&
                notification.metrics.extentAfter < 400 &&
                state.moreError == null) {
              notifier.loadMore();
            }
            return false;
          },
          child: DesktopRefreshIndicator(
            refreshIndicatorKey: _refreshIndicatorKey,
            shouldRefresh: () => widget.isActive,
            onRefresh: () => _refresh(notifier),
            child: ListView.builder(
              key: PageStorageKey('following_feed_$username'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              itemCount: state.posts.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // 首次加载占位；刷新保留原状态，由下拉指示器反馈。
                  return AppLoadingSwitcher(
                    identity: username,
                    loading: state.loading,
                    delay: Duration.zero,
                    loadingBuilder: (_) => refreshing
                        ? const SizedBox.shrink()
                        : const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: LoadingSpinner()),
                          ),
                    child: state.error != null
                        ? ErrorView(
                            error: state.error!,
                            onRetry: () =>
                                _refreshIndicatorKey.currentState?.show(),
                          )
                        : state.posts.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32),
                            child: AppEmptyState(
                              icon: const Icon(Symbols.group_rounded),
                              title: context.l10n.followingFeed_empty,
                              message: context.l10n.followingFeed_emptyHint,
                            ),
                          )
                        : const SizedBox.shrink(),
                  );
                }
                if (index == state.posts.length + 1) {
                  if (state.posts.isEmpty) return const SizedBox.shrink();
                  return Column(
                    children: [
                      PagedListFooter(
                        hasMore: state.hasMore,
                        isLoadingMore: state.loadingMore,
                        isLoadMoreFailed: state.moreError != null,
                        onRetry: notifier.loadMore,
                      ),
                      if (state.hasMore &&
                          !state.loadingMore &&
                          state.moreError == null)
                        TextButton(
                          onPressed: notifier.loadMore,
                          child: Text(context.l10n.followingFeed_loadMore),
                        ),
                    ],
                  );
                }
                final post = state.posts[index - 1];
                return ActivityPostCard(
                  key: ValueKey(post.id),
                  position: (index: index - 1, count: state.posts.length),
                  title: post.title,
                  actionLabel: post.postNumber == 1
                      ? context.l10n.followingFeed_posted
                      : context.l10n.followingFeed_replied,
                  author: post.author,
                  occurredAt: post.createdAt,
                  postNumber: post.postNumber,
                  excerpt: post.excerpt,
                  onTap: () => _openPost(post),
                );
              },
            ),
          ),
        ),
      ),
    );
    return MasterDetailPaneHost(
      key: ValueKey(username),
      stackProvider: selectedFollowingFeedProvider,
      isActive: widget.isActive,
      master: _wide
          ? EmbeddedStackScope(
              stackProvider: selectedFollowingFeedProvider,
              truncateOnPush: true,
              child: page,
            )
          : page,
    );
  }
}
