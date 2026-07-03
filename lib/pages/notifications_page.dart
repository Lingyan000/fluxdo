import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/discourse_providers.dart';
import '../providers/preferences_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../utils/notification_navigation.dart';
import '../widgets/notification/notification_item.dart';
import '../widgets/notification/notification_list_skeleton.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../l10n/s.dart';
import '../utils/blocked_user_filter.dart';

/// 通知历史列表页面（独立分页，不受 messageBus 干扰）
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();

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

  void _onScroll() {
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(notificationListProvider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () =>
          ref.read(notificationListProvider).value?.length ?? 0,
    );
  }

  Future<void> _onRefresh() async {
    _loadMoreCoordinator.resetCooldown();
    await ref.read(notificationListProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(notificationListProvider);
    final systemAvatarTemplate = ref
        .watch(systemUserAvatarTemplateProvider)
        .value;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.common_notification),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Symbols.done_all_rounded),
            onPressed: () async {
              await ref.read(notificationListProvider.notifier).markAllAsRead();
              // 快捷面板下次打开时会自动 silentRefresh 同步已读状态
            },
            tooltip: context.l10n.notification_markAllRead,
          ),
        ],
      ),
      body: DesktopRefreshIndicator(
        onRefresh: _onRefresh,
        child: notificationsAsync.when(
          data: (notifications) {
            final blockedUsernames = ref.watch(
              preferencesProvider.select((p) => p.normalizedBlockedUsernames),
            );
            final visibleNotifications = notifications
                .where(
                  (notification) => !BlockedUserFilter.isBlockedNotification(
                    notification,
                    blockedUsernames,
                  ),
                )
                .toList(growable: false);
            final notifier = ref.read(notificationListProvider.notifier);
            // 已加载页全部被本地屏蔽时列表不可滚，滚动触发的翻页永远不会
            // 发生；主动补载下一页（coordinator 自带冷却，不会打转）
            if (visibleNotifications.isEmpty &&
                notifications.isNotEmpty &&
                notifier.hasMore) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _loadMore();
              });
            }
            if (visibleNotifications.isEmpty &&
                (notifications.isEmpty || !notifier.hasMore)) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Symbols.notifications_rounded,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.notification_empty,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              controller: _scrollController,
              itemCount: visibleNotifications.length + 1,
              itemBuilder: (context, index) {
                if (index == visibleNotifications.length) {
                  final notifier = ref.read(notificationListProvider.notifier);
                  return PagedListFooter(
                    hasMore: notifier.hasMore,
                    isLoadingMore: notifier.isLoadingMore,
                    isLoadMoreFailed: notifier.isLoadMoreFailed,
                    onRetry: notifier.retryLoadMore,
                  );
                }
                final notification = visibleNotifications[index];
                return NotificationItem(
                  notification: notification,
                  systemAvatarTemplate: systemAvatarTemplate,
                  onTap: () =>
                      handleNotificationTap(context, ref, notification),
                );
              },
            );
          },
          loading: () => const NotificationListSkeleton(),
          error: (error, stack) =>
              ErrorView(error: error, stackTrace: stack, onRetry: _onRefresh),
        ),
      ),
    );
  }
}
