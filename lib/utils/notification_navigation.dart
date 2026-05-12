import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus/notification_providers.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/badge_page.dart';
import '../services/local_notification_service.dart';
import '../widgets/notification/notification_quick_panel.dart';

NavigatorState? _rootNavigator(BuildContext context) {
  return navigatorKey.currentState ??
      Navigator.of(context, rootNavigator: true);
}

/// 同步本地通知状态，避免角标和不同列表之间状态不一致
void syncNotificationReadLocallyWithNotifiers({
  required DiscourseNotification notification,
  required NotificationCountNotifier countNotifier,
  RecentNotificationsNotifier? recentNotifier,
  NotificationListNotifier? listNotifier,
}) {
  if (notification.read) return;

  recentNotifier?.markAsRead(notification.id);
  listNotifier?.markAsRead(notification.id);
  countNotifier.markRead(highPriority: notification.highPriority);
}

void syncNotificationReadLocally(WidgetRef ref, DiscourseNotification notification) {
  syncNotificationReadLocallyWithNotifiers(
    notification: notification,
    countNotifier: ref.read(notificationCountStateProvider.notifier),
    recentNotifier: ref.exists(recentNotificationsProvider)
        ? ref.read(recentNotificationsProvider.notifier)
        : null,
    listNotifier: ref.exists(notificationListProvider)
        ? ref.read(notificationListProvider.notifier)
        : null,
  );
}

void syncNotificationReadLocallyWithRef(
  Ref ref,
  DiscourseNotification notification,
) {
  syncNotificationReadLocallyWithNotifiers(
    notification: notification,
    countNotifier: ref.read(notificationCountStateProvider.notifier),
    recentNotifier: ref.exists(recentNotificationsProvider)
        ? ref.read(recentNotificationsProvider.notifier)
        : null,
    listNotifier: ref.exists(notificationListProvider)
        ? ref.read(notificationListProvider.notifier)
        : null,
  );
}

void _pushOnRootNavigator(BuildContext context, Widget page) {
  NotificationQuickPanel.dismiss();
  _rootNavigator(context)?.push(MaterialPageRoute(builder: (_) => page));
}

/// 处理通知点击：标记已读 + 按类型跳转
/// 快捷面板和历史列表页面共用
void handleNotificationTap(
  BuildContext context,
  WidgetRef ref,
  DiscourseNotification notification,
) {
  // 如果通知未读，先标记为已读
  if (!notification.read) {
    syncNotificationReadLocally(ref, notification);

    // 异步发送标记已读请求
    ref
        .read(discourseServiceProvider)
        .markNotificationRead(notification.id)
        .catchError((e) {
          debugPrint('标记通知已读失败: $e');
        });
  }

  // 根据通知类型决定跳转逻辑
  switch (notification.notificationType) {
    case NotificationType.inviteeAccepted:
    case NotificationType.following:
      if (notification.username != null) {
        _pushOnRootNavigator(
          context,
          UserProfilePage(username: notification.username!),
        );
      }
      break;

    case NotificationType.grantedBadge:
      if (notification.data.badgeId != null) {
        final currentUser = ref.read(currentUserProvider).value;
        _pushOnRootNavigator(
          context,
          BadgePage(
            badgeId: notification.data.badgeId!,
            badgeSlug: notification.data.badgeSlug,
            username: currentUser?.username,
          ),
        );
      }
      break;

    case NotificationType.membershipRequestAccepted:
      break;

    case NotificationType.boost:
      if (notification.topicId != null) {
        _pushOnRootNavigator(
          context,
          TopicDetailPage(
            topicId: notification.topicId!,
            scrollToPostNumber: notification.postNumber,
            highlightBoostUsername: notification.data.displayUsername,
          ),
        );
      }
      break;

    default:
      if (notification.topicId != null) {
        _pushOnRootNavigator(
          context,
          TopicDetailPage(
            topicId: notification.topicId!,
            scrollToPostNumber: notification.postNumber,
          ),
        );
      }
      break;
  }
}
