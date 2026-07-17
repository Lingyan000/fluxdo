import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../pages/badge_page.dart';
import '../services/local_notification_service.dart';

NavigatorState? _rootNavigator(BuildContext context) {
  return navigatorKey.currentState ??
      Navigator.of(context, rootNavigator: true);
}

void _pushOnRootNavigator(BuildContext context, Widget page) {
  _rootNavigator(context)?.push(MaterialPageRoute(builder: (_) => page));
}

void _showHomeWorkspace(BuildContext context, WidgetRef ref) {
  ref.requestNavDestination(NavEntryIds.home);
  final route = ModalRoute.of(context);
  final navigator = _rootNavigator(context);
  // “全部通知”是盖在主工作区上的独立路由，需要移除；快捷通知面板只是
  // OverlayEntry，根路由本身不可 pop，不会误关主页。
  if (route?.isCurrent == true && navigator?.canPop() == true) {
    navigator!.pop();
  }
}

void _openTopicInWorkspace(
  BuildContext context,
  WidgetRef ref, {
  required int topicId,
  int? postNumber,
  String? highlightBoostUsername,
  int? initialRevisionPostNumber,
  int? initialRevisionNumber,
}) {
  ref
      .read(selectedTopicProvider.notifier)
      .select(
        topicId: topicId,
        scrollToPostNumber: postNumber,
        highlightBoostUsername: highlightBoostUsername,
        initialRevisionPostNumber: initialRevisionPostNumber,
        initialRevisionNumber: initialRevisionNumber,
      );
  _showHomeWorkspace(context, ref);
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
    // 更新快捷面板本地状态
    ref.read(recentNotificationsProvider.notifier).markAsRead(notification.id);

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
        ref
            .read(selectedTopicProvider.notifier)
            .selectProfile(notification.username!);
        _showHomeWorkspace(context, ref);
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
        _openTopicInWorkspace(
          context,
          ref,
          topicId: notification.topicId!,
          postNumber: notification.postNumber,
          highlightBoostUsername: notification.data.displayUsername,
        );
      }
      break;

    case NotificationType.edited:
      // 帖子被编辑通知:跳转到对应话题 + 打开编辑历史 modal 到指定 revision。
      // 对齐 discourse 网页版 `edited.js` 的 `setLastEditNotificationClick` 逻辑。
      if (notification.topicId != null) {
        _openTopicInWorkspace(
          context,
          ref,
          topicId: notification.topicId!,
          postNumber: notification.postNumber,
          initialRevisionPostNumber: notification.postNumber,
          initialRevisionNumber: notification.data.revisionNumber,
        );
      }
      break;

    default:
      if (notification.topicId != null) {
        _openTopicInWorkspace(
          context,
          ref,
          topicId: notification.topicId!,
          postNumber: notification.postNumber,
        );
      }
      break;
  }
}
