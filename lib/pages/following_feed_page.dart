import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/following_feed.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/category_provider.dart';
import '../providers/core_providers.dart';
import '../providers/following_feed_migration_provider.dart';
import '../providers/following_feed_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../utils/blocked_user_filter.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/master_detail_pane_host.dart';
import '../widgets/user/activity_card_layout.dart';
import '../widgets/user/activity_post_card.dart';
import '../widgets/user/following_feed_migration_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import 'follow_list_page.dart';
import 'topic_detail_page/topic_detail_page.dart';

@visibleForTesting
bool isFollowingPostSelected({
  required bool wide,
  required PaneEntry? selectedTop,
  required FollowingPost post,
}) =>
    wide &&
    selectedTop?.kind == PaneKind.topic &&
    selectedTop?.topicId == post.topicId &&
    (selectedTop?.scrollToPostNumber == null ||
        selectedTop?.scrollToPostNumber == post.postNumber);

class FollowingFeedPage extends ConsumerStatefulWidget {
  const FollowingFeedPage({super.key, this.isActive = true});
  final bool isActive;
  @override
  ConsumerState<FollowingFeedPage> createState() => _FollowingFeedPageState();
}

class _FollowingFeedPageState extends ConsumerState<FollowingFeedPage> {
  final _scroll = ScrollController();
  final _refreshIndicatorKey = GlobalKey<M3eRefreshIndicatorState>();
  final _loadMoreCoordinator = LoadMoreCoordinator(
    triggerDistance: 400,
    releaseDistance: 400,
  );
  String? _currentUsername;
  bool _activated = false;
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    _publishScrollProgress();
    if (!widget.isActive || !_scroll.hasClients) return;
    final username = _currentUsername;
    if (username == null) return;
    final distance =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance) &&
        ref.read(followingFeedProvider(username)).moreError == null) {
      _loadMore();
    }
  }

  void _publishScrollProgress() {
    if (!_scroll.hasClients) return;
    final raw = _scroll.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(
      navScrollProgressProvider(NavEntryIds.followingFeed),
    );
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref
            .read(navScrollProgressProvider(NavEntryIds.followingFeed).notifier)
            .state =
        progress;
  }

  Future<void> _loadMore() async {
    final username = _currentUsername;
    if (username == null) return;
    final provider = followingFeedProvider(username);
    final notifier = ref.read(provider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => ref.read(provider).hasMore,
      isActive: () =>
          mounted && widget.isActive && _currentUsername == username,
      progressCount: () => ref.read(provider).posts.length,
    );
  }

  Future<void> _retryLoadMore() async {
    _loadMoreCoordinator.resetCooldown();
    await _loadMore();
  }

  Future<void> _refresh(FollowingFeedNotifier notifier) async {
    _loadMoreCoordinator.resetCooldown();
    await notifier.refresh();
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

  Widget _buildScrollableState({
    required double bottomInset,
    required Widget child,
  }) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: child,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // 导航预建的隐藏页面不发请求；访问过后保留列表及滚动位置。
    _activated = _activated || widget.isActive;
    if (!_activated) return const SizedBox.shrink();
    final username = ref.watch(currentUserProvider).value?.username;
    if (_currentUsername != username) {
      _currentUsername = username;
      _loadMoreCoordinator.resetCooldown();
    }
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    if (username == null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.followingFeed_title)),
        body: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: AppEmptyState(
            icon: const Icon(Symbols.rss_feed_rounded),
            title: context.l10n.followingFeed_login,
          ),
        ),
      );
    }
    ref.listen(navActionBusProvider, (_, event) {
      if (!widget.isActive ||
          event == null ||
          event.targetId != NavEntryIds.followingFeed) {
        return;
      }
      switch (event.action) {
        case NavAction.scrollToTop:
          if (_scroll.hasClients) {
            _scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case NavAction.refresh:
          if (ref.read(followingFeedProvider(username)).loading) return;
          if (_scroll.hasClients) {
            _scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _refreshIndicatorKey.currentState?.show();
          ref.resetNavScrollProgress(NavEntryIds.followingFeed);
          break;
      }
    });
    final state = ref.watch(followingFeedProvider(username));
    final notifier = ref.read(followingFeedProvider(username).notifier);
    final migration = ref.watch(followingFeedMigrationProvider);
    if (widget.isActive &&
        migration.showGuide &&
        ModalRoute.isCurrentOf(context) == true) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showMigrationGuide(username),
      );
    }
    final categories = ref.watch(categoryMapProvider).value ?? const {};
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    final selectedTop = ref.watch(
      selectedFollowingFeedProvider.select((s) => s.topEntry),
    );
    final visiblePosts = blockedUsernames.isEmpty
        ? state.posts
        : state.posts
              .where(
                (post) => !BlockedUserFilter.isBlockedUsername(
                  post.author.username,
                  blockedUsernames,
                ),
              )
              .toList(growable: false);
    if (visiblePosts.isEmpty &&
        state.posts.isNotEmpty &&
        state.hasMore &&
        !state.loading &&
        !state.loadingMore &&
        state.moreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMore();
      });
    }
    _wide = MasterDetailLayout.canShowBothPanesFor(context);

    final Widget body;
    if (!state.initialized && state.loading) {
      body = const UserActionListSkeleton(type: UserActivitySkeletonType.post);
    } else if (state.error != null) {
      body = _buildScrollableState(
        bottomInset: bottomInset,
        child: ErrorView(
          error: state.error!,
          stackTrace: state.errorStack,
          onRetry: () => _refreshIndicatorKey.currentState?.show(),
        ),
      );
    } else if (visiblePosts.isEmpty &&
        (state.posts.isEmpty || !state.hasMore)) {
      body = _buildScrollableState(
        bottomInset: bottomInset,
        child: AppEmptyState(
          icon: const Icon(Symbols.group_rounded),
          title: context.l10n.followingFeed_empty,
          message: context.l10n.followingFeed_emptyHint,
        ),
      );
    } else {
      body = ActivityCardList(
        builder: (context, padding) => ListView.builder(
          key: PageStorageKey('following_feed_$username'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding.copyWith(bottom: padding.bottom + bottomInset),
          itemCount: visiblePosts.length + 1,
          itemBuilder: (context, index) {
            if (index == visiblePosts.length) {
              return PagedListFooter(
                hasMore: state.hasMore,
                isLoadingMore: state.loadingMore,
                isLoadMoreFailed: state.moreError != null,
                onRetry: _retryLoadMore,
              );
            }
            final post = visiblePosts[index];
            final isNewTopic = post.postNumber == 1;
            final isSelected = isFollowingPostSelected(
              wide: _wide,
              selectedTop: selectedTop,
              post: post,
            );
            return ActivityPostCard(
              key: ValueKey(post.id),
              position: (index: index, count: visiblePosts.length),
              highlighted: isSelected,
              title: post.title,
              actionLabel: isNewTopic
                  ? context.l10n.followingFeed_posted
                  : context.l10n.followingFeed_replied,
              actionIcon: isNewTopic
                  ? Symbols.article_rounded
                  : Symbols.reply_rounded,
              bodyFirst: !isNewTopic,
              author: post.author,
              occurredAt: post.createdAt,
              postNumber: post.postNumber,
              excerpt: post.excerpt,
              categoryId: post.categoryId,
              categories: categories,
              onTap: () => _openPost(post),
            );
          },
        ),
      );
    }

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
        ],
      ),
      body: DesktopRefreshIndicator(
        refreshIndicatorKey: _refreshIndicatorKey,
        shouldRefresh: () => widget.isActive,
        onRefresh: () => _refresh(notifier),
        child: body,
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
