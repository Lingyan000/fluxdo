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
import 'follow_list_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'user_profile_page.dart';

class FollowingFeedPage extends ConsumerStatefulWidget {
  const FollowingFeedPage({super.key, this.isActive = true});
  final bool isActive;
  @override
  ConsumerState<FollowingFeedPage> createState() => _FollowingFeedPageState();
}

class _FollowingFeedPageState extends ConsumerState<FollowingFeedPage> {
  final _scroll = ScrollController();
  bool _activated = false;
  bool _wide = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
        ref.read(followingFeedProvider(username).notifier).refresh();
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
    final migration = ref.watch(followingFeedMigrationProvider);
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
            onPressed: state.loading ? null : notifier.refresh,
          ),
          if (migration.usedSeeking)
            IconButton(
              tooltip: context.l10n.followingFeed_migrationTitle,
              icon: const Icon(Symbols.info_rounded),
              onPressed: () => _showMigration(context),
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
            shouldRefresh: () => widget.isActive,
            onRefresh: notifier.refresh,
            child: ListView.builder(
              key: PageStorageKey('following_feed_$username'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              itemCount: state.posts.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    children: [
                      if (migration.showGuide)
                        _FollowingFeedMigrationCard(
                          onOpen: () => _showMigration(context),
                        ),
                      if (state.loading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: LoadingSpinner()),
                        ),
                      if (state.error != null)
                        ErrorView(
                          error: state.error!,
                          onRetry: notifier.refresh,
                        ),
                      if (!state.loading &&
                          state.error == null &&
                          state.posts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: AppEmptyState(
                            icon: const Icon(Symbols.group_rounded),
                            title: context.l10n.followingFeed_empty,
                            message: context.l10n.followingFeed_emptyHint,
                          ),
                        ),
                    ],
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

  void _showMigration(BuildContext context) => Navigator.of(context).push(
    InteractionPageRoute(builder: (_) => const FollowingFeedMigrationPage()),
  );
}

/// 动态页内的追觅迁移入口。
class _FollowingFeedMigrationCard extends StatelessWidget {
  const _FollowingFeedMigrationCard({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Symbols.info_rounded),
        title: Text(context.l10n.followingFeed_migrationTitle),
        subtitle: Text(context.l10n.followingFeed_migrationSummary),
        trailing: const Icon(Symbols.chevron_right_rounded),
        onTap: onOpen,
      ),
    );
  }
}

class FollowingFeedMigrationPage extends ConsumerWidget {
  const FollowingFeedMigrationPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final migration = ref.watch(followingFeedMigrationProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.followingFeed_migrationTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.followingFeed_migrationBody),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await ref.read(followingFeedMigrationProvider.notifier).dismiss();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(context.l10n.common_gotIt),
          ),
          if (migration.users.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(context.l10n.followingFeed_legacyUsers),
            const SizedBox(height: 8),
            Text(context.l10n.followingFeed_legacyHint),
            for (final username in migration.users)
              ListTile(
                title: Text(username),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  InteractionPageRoute(
                    builder: (_) => UserProfilePage(username: username),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
