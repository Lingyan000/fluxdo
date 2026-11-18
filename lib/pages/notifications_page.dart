import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/notification.dart';
import '../models/user_action.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/notification_activity_provider.dart';
import '../providers/preferences_provider.dart';
import '../utils/blocked_user_filter.dart';
import '../utils/responsive.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/notification_navigation.dart';
import '../utils/paged_async_notifier.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../widgets/notification/notification_card.dart';
import '../widgets/notification/notification_list_skeleton.dart';
import '../widgets/post/post_boost/boost_content.dart';
import '../widgets/user/activity_card_layout.dart';
import '../widgets/user/activity_post_card.dart';
import '../widgets/user/user_profile_skeleton.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 通知页栏目。「全部」来自通知接口并可按已读状态筛选；其余栏目与网页
/// 通知页一致，来自当前用户的活动流，没有已读状态。
enum _NotificationTab {
  all,
  replies,
  mentions,
  likes,
  reactions,
  boosts,
  edits,
  links;

  NotificationActionStream? get stream => switch (this) {
    replies => NotificationActionStream.replies,
    mentions => NotificationActionStream.mentions,
    likes => NotificationActionStream.likes,
    edits => NotificationActionStream.edits,
    links => NotificationActionStream.links,
    all || reactions || boosts => null,
  };

  IconData get icon => switch (this) {
    all => Symbols.notifications_rounded,
    replies => Symbols.reply_rounded,
    mentions => Symbols.alternate_email_rounded,
    likes => Symbols.favorite_rounded,
    reactions => Symbols.add_reaction_rounded,
    boosts => Symbols.rocket_launch_rounded,
    edits => Symbols.edit_rounded,
    links => Symbols.link_rounded,
  };

  String label(BuildContext context) => switch (this) {
    all => context.l10n.common_all,
    replies => context.l10n.notification_tabReplies,
    mentions => context.l10n.notification_tabMentions,
    likes => context.l10n.notification_tabLikes,
    reactions => context.l10n.notification_tabReactions,
    boosts => context.l10n.notification_typeBoost,
    edits => context.l10n.notification_tabEdits,
    links => context.l10n.notification_tabLinks,
  };
}

extension on NotificationReadFilter {
  String label(BuildContext context) => switch (this) {
    NotificationReadFilter.all => context.l10n.notification_filterAll,
    NotificationReadFilter.unread => context.l10n.notification_filterUnread,
    NotificationReadFilter.read => context.l10n.notification_filterRead,
  };

  IconData get icon => switch (this) {
    NotificationReadFilter.all => Symbols.notifications_rounded,
    NotificationReadFilter.unread => Symbols.notifications_unread_rounded,
    NotificationReadFilter.read => Symbols.done_all_rounded,
  };
}

/// 通知历史页面（独立分页，不受 messageBus 干扰）
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: _NotificationTab.values.length,
    vsync: this,
  );
  NotificationReadFilter _readFilter = NotificationReadFilter.all;

  /// 宽屏下访问过的栏目，未访问的不构建，避免一次请求全部栏目
  final Set<_NotificationTab> _visited = {_NotificationTab.all};

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _select(_NotificationTab tab, {NotificationReadFilter? filter}) {
    setState(() {
      if (filter != null) _readFilter = filter;
      _visited.add(tab);
    });
    _tabController.index = tab.index;
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = ref.watch(
      notificationCountStateProvider.select((s) => s.totalUnread),
    );
    final hasUnreadInList = ref.watch(
      notificationListProvider(
        _readFilter,
      ).select((v) => v.value?.any((n) => !n.read) ?? false),
    );
    final canMarkRead = totalUnread > 0 || hasUnreadInList;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= NotificationsWideLayout.minWidth;
        Widget view(_NotificationTab tab) => switch (tab) {
          _NotificationTab.all => _NotificationStreamTab(
            key: ValueKey(_readFilter),
            filter: _readFilter,
          ),
          _NotificationTab.reactions => const _ReceivedReactionsTab(),
          _NotificationTab.boosts => const _ReceivedBoostsTab(),
          _ => _ActionStreamTab(stream: tab.stream!),
        };
        final current = _NotificationTab.values[_tabController.index];
        // 侧栏是并列切换，没有前后方向，直接切换而不横向滑动
        final Widget content = wide
            ? IndexedStack(
                index: current.index,
                sizing: StackFit.expand,
                children: [
                  for (final tab in _NotificationTab.values)
                    tab == current || _visited.contains(tab)
                        ? view(tab)
                        : const SizedBox.shrink(),
                ],
              )
            : TabBarView(
                controller: _tabController,
                children: [
                  for (final tab in _NotificationTab.values) view(tab),
                ],
              );
        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.common_notification),
            centerTitle: true,
            actions: [
              IconButton(
                icon: const Icon(Symbols.done_all_rounded),
                onPressed: canMarkRead
                    ? () async {
                        await ref
                            .read(notificationCountStateProvider.notifier)
                            .markAllNotificationsRead();
                      }
                    : null,
                tooltip: context.l10n.notification_markAllRead,
              ),
            ],
            bottom: wide ? null : _buildTabBar(context),
          ),
          body: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: NotificationsWideLayout.sideNavWidth,
                      child: AnimatedBuilder(
                        animation: _tabController,
                        builder: (context, _) => _SideNav(
                          tab: _NotificationTab.values[_tabController.index],
                          readFilter: _readFilter,
                          onSelected: _select,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: Breakpoints.maxContentWidth,
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  ],
                )
              : content,
        );
      },
    );
  }

  MenuTabBar<NotificationReadFilter> _buildTabBar(BuildContext context) =>
      MenuTabBar<NotificationReadFilter>(
        controller: _tabController,
        // 分类筛选需要一眼读懂：常驻文字，选中项显现图标，与通知面板一致
        mode: MenuTabMode.label,
        items: [
          for (final tab in _NotificationTab.values)
            tab == _NotificationTab.all
                ? MenuTabItem(
                    label: _readFilter == NotificationReadFilter.all
                        ? tab.label(context)
                        : _readFilter.label(context),
                    icon: tab.icon,
                    selectedValue: _readFilter,
                    onSelected: (filter) => _select(tab, filter: filter),
                    menuBuilder: (_) => [
                      for (final filter in NotificationReadFilter.values)
                        CheckedPopupMenuItem(
                          value: filter,
                          checked: filter == _readFilter,
                          child: Text(filter.label(context)),
                        ),
                    ],
                  )
                : MenuTabItem(label: tab.label(context), icon: tab.icon),
        ],
      );
}

/// 宽屏左侧导航：已读筛选直接展开为一组，栏目为另一组
class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.tab,
    required this.readFilter,
    required this.onSelected,
  });

  final _NotificationTab tab;
  final NotificationReadFilter readFilter;
  final void Function(_NotificationTab tab, {NotificationReadFilter? filter})
  onSelected;

  @override
  Widget build(BuildContext context) {
    Widget item({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) => ListTile(
      key: ValueKey(label),
      leading: Icon(
        icon,
        color: selected ? context.emphasis.selected : context.emphasis.accent,
      ),
      title: Text(
        label,
        style: selected ? const TextStyle(fontWeight: FontWeight.w600) : null,
      ),
      selected: selected,
      selectedColor: context.emphasis.selected,
      selectedTileColor: context.emphasis.selected.withValues(alpha: 0.1),
      onTap: onTap,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
      children: [
        SegmentedCardGroup(
          children: [
            for (final filter in NotificationReadFilter.values)
              item(
                icon: filter.icon,
                label: filter.label(context),
                selected: tab == _NotificationTab.all && filter == readFilter,
                onTap: () => onSelected(_NotificationTab.all, filter: filter),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedCardGroup(
          children: [
            for (final other in _NotificationTab.values)
              if (other != _NotificationTab.all)
                item(
                  icon: other.icon,
                  label: other.label(context),
                  selected: tab == other,
                  onTap: () => onSelected(other),
                ),
          ],
        ),
      ],
    );
  }
}

/// 栏目内容：首屏骨架、错误、空态、下拉刷新与触底翻页。
/// 切走后保留滚动位置和已加载数据。
class _PagedTab<T> extends StatefulWidget {
  const _PagedTab({
    required this.value,
    required this.notifier,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetry,
    required this.skeleton,
    required this.emptyTitle,
    required this.visibleItems,
    required this.list,
  });

  final AsyncValue<List<T>> value;
  final PagedAsyncNotifierMixin<T> notifier;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLoadMore;
  final Future<void> Function() onRetry;
  final Widget skeleton;
  final String emptyTitle;

  /// 过滤掉本地屏蔽用户后的条目
  final List<T> Function(List<T> items) visibleItems;

  /// 由可见条目生成列表的条目数和构建函数，不含底部分页条
  final ({int count, IndexedWidgetBuilder builder}) Function(List<T> items)
  list;

  @override
  State<_PagedTab<T>> createState() => _PagedTabState<T>();
}

class _PagedTabState<T> extends State<_PagedTab<T>>
    with AutomaticKeepAliveClientMixin {
  final LoadMoreCoordinator _coordinator = LoadMoreCoordinator();

  @override
  bool get wantKeepAlive => true;

  Future<void> _loadMore() => _coordinator.loadMore(
    loadMore: widget.onLoadMore,
    hasMore: () => widget.notifier.hasMore,
    isActive: () => mounted,
    progressCount: () => widget.value.value?.length ?? 0,
  );

  Future<void> _refresh() async {
    _coordinator.resetCooldown();
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final notifier = widget.notifier;
    return DesktopRefreshIndicator(
      onRefresh: _refresh,
      child: widget.value.when(
        data: (items) {
          final visible = widget.visibleItems(items);
          // 已加载页全部被本地屏蔽时列表不可滚，滚动触发的翻页永远不会
          // 发生；主动补载下一页（coordinator 自带冷却，不会打转）
          if (visible.isEmpty && items.isNotEmpty && notifier.hasMore) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadMore();
            });
          }
          if (visible.isEmpty && (items.isEmpty || !notifier.hasMore)) {
            return AppEmptyState(
              icon: const Icon(Symbols.notifications_rounded),
              title: widget.emptyTitle,
            );
          }
          final list = widget.list(visible);
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  _coordinator.shouldTriggerForDistance(
                    notification.metrics.maxScrollExtent -
                        notification.metrics.pixels,
                  )) {
                _loadMore();
              }
              return false;
            },
            child: ActivityCardList(
              builder: (context, padding) => ListView.builder(
                padding: padding,
                itemCount: list.count + 1,
                itemBuilder: (context, index) {
                  if (index == list.count) {
                    return PagedListFooter(
                      hasMore: notifier.hasMore,
                      isLoadingMore: notifier.isLoadingMore,
                      isLoadMoreFailed: notifier.isLoadMoreFailed,
                      onRetry: widget.onRetry,
                    );
                  }
                  return list.builder(context, index);
                },
              ),
            ),
          );
        },
        loading: () => widget.skeleton,
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: _refresh),
      ),
    );
  }
}

/// 「全部」栏目：按日期分组的通知卡
class _NotificationStreamTab extends ConsumerWidget {
  const _NotificationStreamTab({super.key, required this.filter});

  final NotificationReadFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = notificationListProvider(filter);
    final notifier = ref.read(provider.notifier);
    final systemAvatarTemplate = ref
        .watch(systemUserAvatarTemplateProvider)
        .value;
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return _PagedTab<DiscourseNotification>(
      value: ref.watch(provider),
      notifier: notifier,
      onRefresh: notifier.refresh,
      onLoadMore: notifier.loadMore,
      onRetry: notifier.retryLoadMore,
      skeleton: const NotificationCardListSkeleton(),
      emptyTitle: filter == NotificationReadFilter.unread
          ? context.l10n.notification_emptyUnread
          : context.l10n.notification_empty,
      visibleItems: (items) => items
          .where(
            (n) =>
                !BlockedUserFilter.isBlockedNotification(n, blockedUsernames),
          )
          .toList(growable: false),
      list: (notifications) {
        final entries = _sectionEntries(context, notifications);
        return (
          count: entries.length,
          builder: (context, index) => switch (entries[index]) {
            _SectionHeader(:final label, :final first) => _DateHeader(
              label: label,
              first: first,
            ),
            _SectionItem(index: final i, :final position) => NotificationCard(
              notification: notifications[i],
              position: position,
              systemAvatarTemplate: systemAvatarTemplate,
              // siblings = 当前已加载列表,大屏弹窗内可上一条/下一条
              onTap: () => handleNotificationTap(
                context,
                ref,
                notifications[i],
                siblings: notifications,
              ),
            ),
          },
        );
      },
    );
  }
}

/// 活动流栏目：被回复、被提及、获赞、被编辑、被链接
class _ActionStreamTab extends ConsumerWidget {
  const _ActionStreamTab({required this.stream});

  final NotificationActionStream stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = notificationActionsProvider(stream);
    final notifier = ref.read(provider.notifier);
    final me = ref.watch(
      currentUserProvider.select((user) => user.value?.username),
    );
    final categories = ref.watch(categoryMapProvider).value ?? const {};
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return _PagedTab<UserAction>(
      value: ref.watch(provider),
      notifier: notifier,
      onRefresh: notifier.refresh,
      onLoadMore: notifier.loadMore,
      onRetry: notifier.retryLoadMore,
      skeleton: UserActionListSkeleton(
        type:
            stream == NotificationActionStream.replies ||
                stream == NotificationActionStream.mentions
            ? UserActivitySkeletonType.actorPost
            : UserActivitySkeletonType.receivedLike,
      ),
      emptyTitle: context.l10n.notification_empty,
      visibleItems: (items) => items
          .where(
            (a) => !BlockedUserFilter.isBlockedUsername(
              a.username,
              blockedUsernames,
            ),
          )
          .toList(growable: false),
      list: (actions) => (
        count: actions.length,
        builder: (context, index) {
          final action = actions[index];
          return ActivityPostCard(
            position: (index: index, count: actions.length),
            author: action.author,
            actionActor: action.actor,
            actorVerb: _verbOf(context, action.actionType),
            actionLabel: _verbOf(context, action.actionType),
            title: action.title,
            occurredAt: action.actingAt,
            postNumber: action.postNumber,
            excerpt: action.excerpt,
            // 帖子是自己写的（获赞、被编辑）时原文只作引用
            quoteExcerpt: me != null && action.author?.username == me,
            categoryId: action.categoryId,
            categories: categories,
            onTap: () => _openPost(context, action.topicId, action.postNumber),
          );
        },
      ),
    );
  }

  static String _verbOf(BuildContext context, int? type) => switch (type) {
    UserActionType.quote => context.l10n.notification_verbQuoted,
    UserActionType.mention => context.l10n.notification_verbMentioned,
    UserActionType.wasLiked => context.l10n.notification_verbLiked,
    UserActionType.edit => context.l10n.notification_verbEdited,
    UserActionType.linked => context.l10n.notification_verbLinked,
    _ => context.l10n.notification_verbReplied,
  };
}

/// 「回应」栏目：收到的回应（discourse-reactions 插件）
class _ReceivedReactionsTab extends ConsumerWidget {
  const _ReceivedReactionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(receivedReactionsProvider.notifier);
    final categories = ref.watch(categoryMapProvider).value ?? const {};
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return _PagedTab<UserReaction>(
      value: ref.watch(receivedReactionsProvider),
      notifier: notifier,
      onRefresh: notifier.refresh,
      onLoadMore: notifier.loadMore,
      onRetry: notifier.retryLoadMore,
      skeleton: const UserActionListSkeleton(
        type: UserActivitySkeletonType.receivedLike,
      ),
      emptyTitle: context.l10n.notification_empty,
      visibleItems: (items) => items
          .where(
            (r) => !BlockedUserFilter.isBlockedUsername(
              r.actor?.username,
              blockedUsernames,
            ),
          )
          .toList(growable: false),
      list: (reactions) => (
        count: reactions.length,
        builder: (context, index) {
          final reaction = reactions[index];
          return ActivityPostCard(
            position: (index: index, count: reactions.length),
            author: reaction.author,
            actionActor: reaction.actor,
            actorVerb: context.l10n.notification_verbReacted,
            actionLabel: context.l10n.notification_verbReacted,
            title: reaction.topicTitle ?? '',
            occurredAt: reaction.createdAt,
            postNumber: reaction.postNumber,
            excerpt: reaction.excerpt,
            quoteExcerpt: true,
            reactionId: reaction.reactionValue,
            categoryId: reaction.categoryId,
            categories: categories,
            onTap: () =>
                _openPost(context, reaction.topicId, reaction.postNumber),
          );
        },
      ),
    );
  }
}

/// 「Boost」栏目：收到的 Boost（discourse-boosts 插件）
class _ReceivedBoostsTab extends ConsumerWidget {
  const _ReceivedBoostsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(receivedBoostsProvider.notifier);
    final categories = ref.watch(categoryMapProvider).value ?? const {};
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return _PagedTab<UserBoost>(
      value: ref.watch(receivedBoostsProvider),
      notifier: notifier,
      onRefresh: notifier.refresh,
      onLoadMore: notifier.loadMore,
      onRetry: notifier.retryLoadMore,
      skeleton: const UserActionListSkeleton(
        type: UserActivitySkeletonType.actorPost,
      ),
      emptyTitle: context.l10n.notification_empty,
      visibleItems: (items) => items
          .where(
            (b) => !BlockedUserFilter.isBlockedUsername(
              b.booster?.username,
              blockedUsernames,
            ),
          )
          .toList(growable: false),
      list: (boosts) => (
        count: boosts.length,
        builder: (context, index) {
          final boost = boosts[index];
          final text = BoostContentParser.parse(boost.cooked).displayText;
          return ActivityPostCard(
            position: (index: index, count: boosts.length),
            author: boost.author,
            actionActor: boost.booster,
            actorVerb: context.l10n.notification_verbBoosted,
            actionLabel: context.l10n.notification_verbBoosted,
            actionIcon: Symbols.rocket_launch_rounded,
            title: boost.topicTitle ?? '',
            occurredAt: boost.createdAt,
            postNumber: boost.postNumber,
            excerpt: boost.excerpt,
            quoteExcerpt: true,
            boostNote: text.isEmpty || boost.booster == null
                ? null
                : ActivityBoostNote(actor: boost.booster!, text: text),
            categoryId: boost.categoryId,
            categories: categories,
            onTap: () => _openPost(context, boost.topicId, boost.postNumber),
          );
        },
      ),
    );
  }
}

void _openPost(BuildContext context, int topicId, int? postNumber) =>
    openNotificationPage(
      context,
      TopicDetailPage(topicId: topicId, scrollToPostNumber: postNumber),
    );

sealed class _SectionEntry {
  const _SectionEntry();
}

class _SectionHeader extends _SectionEntry {
  const _SectionHeader(this.label, {required this.first});
  final String label;
  final bool first;
}

class _SectionItem extends _SectionEntry {
  const _SectionItem(this.index, this.position);

  /// 在通知列表中的下标
  final int index;
  final ({int index, int count}) position;
}

/// 按今天、昨天、本周、更早把已按时间倒序的通知分段，
/// 每段内单独计算分段卡片的首尾位置。
List<_SectionEntry> _sectionEntries(
  BuildContext context,
  List<DiscourseNotification> notifications,
) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  // DateTime.weekday 周一为 1、周日为 7；firstDayOfWeekIndex 周日为 0
  final firstDay = MaterialLocalizations.of(context).firstDayOfWeekIndex;
  final weekStart = today.subtract(
    Duration(days: (today.weekday % 7 - firstDay + 7) % 7),
  );
  String labelOf(DateTime time) {
    final day = DateTime(time.year, time.month, time.day);
    // 跨夏令时的日子不足 24 小时，按小时四舍五入得到自然日差
    final days = (today.difference(day).inHours / 24).round();
    if (days <= 0) return context.l10n.time_today;
    if (days == 1) return context.l10n.time_yesterday;
    if (!day.isBefore(weekStart)) {
      return context.l10n.notification_groupThisWeek;
    }
    return context.l10n.notification_groupEarlier;
  }

  final entries = <_SectionEntry>[];
  var start = 0;
  while (start < notifications.length) {
    final label = labelOf(notifications[start].createdAt);
    var end = start + 1;
    while (end < notifications.length &&
        labelOf(notifications[end].createdAt) == label) {
      end++;
    }
    entries.add(_SectionHeader(label, first: start == 0));
    for (var i = start; i < end; i++) {
      entries.add(_SectionItem(i, (index: i - start, count: end - start)));
    }
    start = end;
  }
  return entries;
}

/// 日期分组标题，与卡片正文左缘对齐
class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label, required this.first});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 4 : 20, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
