import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import '../providers/discourse_providers.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/badge_page.dart';

/// 处理通知点击：标记已读 + 按类型跳转
/// 快捷面板和历史列表页面共用
void handleNotificationTap(
  BuildContext context,
  WidgetRef ref,
  DiscourseNotification notification,
) {
  // 如果通知未读，先标记为已读
  if (!notification.read) {
    // 更新快捷面板本地状态
    ref.read(recentNotificationsProvider.notifier).markAsRead(notification.id);

    // 异步发送标记已读请求
    ref.read(discourseServiceProvider).markNotificationRead(notification.id).catchError((e) {
      debugPrint('标记通知已读失败: $e');
    });
  }

  // 根据通知类型决定跳转逻辑
  switch (notification.notificationType) {
    case NotificationType.inviteeAccepted:
    case NotificationType.following:
      if (notification.username != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfilePage(username: notification.username!),
          ),
        );
      }
      break;

    case NotificationType.grantedBadge:
      if (notification.data.badgeId != null) {
        final currentUser = ref.read(currentUserProvider).value;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BadgePage(
              badgeId: notification.data.badgeId!,
              badgeSlug: notification.data.badgeSlug,
              username: currentUser?.username,
            ),
          ),
        );
      }
      break;

    case NotificationType.membershipRequestAccepted:
      break;

    case NotificationType.boost:
      if (notification.topicId != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: notification.topicId!,
              scrollToPostNumber: notification.postNumber,
              highlightBoostUsername: notification.data.displayUsername,
            ),
          ),
        );
      }
      break;

    default:
      if (notification.topicId != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: notification.topicId!,
              scrollToPostNumber: notification.postNumber,
            ),
          ),
        );
      }
      break;
  }
}
