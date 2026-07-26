import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/notification.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/topic_detail_provider.dart';
import '../pages/badge_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../services/local_notification_service.dart';
import '../widgets/layout/master_detail_layout.dart';

NavigatorState? _rootNavigator(BuildContext context) {
  return navigatorKey.currentState ??
      Navigator.of(context, rootNavigator: true);
}

void _pushOnRootNavigator(BuildContext context, Widget page) {
  _rootNavigator(context)?.push(MaterialPageRoute(builder: (_) => page));
}

void _showWorkspace(BuildContext context, WidgetRef ref, String targetId) {
  ref.requestNavDestination(targetId);
  final route = ModalRoute.of(context);
  final navigator = _rootNavigator(context);
  // “全部通知”是盖在主工作区上的独立路由，需要移除；快捷通知面板只是
  // OverlayEntry，根路由本身不可 pop，不会误关主页。
  if (route?.isCurrent == true && navigator?.canPop() == true) {
    navigator!.pop();
  }
}

void _showHomeWorkspace(BuildContext context, WidgetRef ref) {
  _showWorkspace(context, ref, NavEntryIds.home);
}

/// 窄屏（单栏）没有「工作区栈写入 → 打开全屏详情」这座桥：TopicsScreen
/// 只在宽→窄布局切换或 tab 重新激活时才补 push 全屏路由，而已经在目标
/// tab 上时 [NavActionDispatch.requestNavDestination] 是 no-op——select()
/// 只会静默写栈，用户看不到任何跳转。所以窄屏必须走全屏路由入口，
/// 只有真能同屏摆下双栏时才交给平行视界栈。
bool _useWorkspaceNavigation(BuildContext context) =>
    MasterDetailLayout.canShowBothPanesFor(context);

/// 私信类通知专用:走 [selectedMessageProvider]（私信栏自己的平行视界栈），
/// 并切到"私信" tab——不能像普通话题通知那样落进 [selectedTopicProvider]/
/// 首页信息流栈，否则左栏会显示信息流而不是私信列表，跟从私信列表点进去
/// 的表现不一致。
void _openMessageInWorkspace(
  BuildContext context,
  WidgetRef ref, {
  required int topicId,
  int? postNumber,
  String? instanceId,
}) {
  if (!_useWorkspaceNavigation(context)) {
    _pushOnRootNavigator(
      context,
      TopicDetailPage(
        topicId: topicId,
        scrollToPostNumber: postNumber,
        instanceId: instanceId,
        // 中途拉宽窗口时自动收回私信栏的平行视界，而不是留在全屏页
        autoSwitchToMasterDetail: true,
        stackProvider: selectedMessageProvider,
      ),
    );
    return;
  }
  ref
      .read(selectedMessageProvider.notifier)
      .select(
        topicId: topicId,
        scrollToPostNumber: postNumber,
        instanceId: instanceId,
      );
  _showWorkspace(context, ref, NavEntryIds.messages);
}

/// 通知类型本身（除 privateMessage/invitedToPrivateMessage 外）不带
/// "这条通知挂的话题是不是私信"这个信息——posted/boost/edited/liked 等
/// 通用类型，只要发生在私信话题下，都得走私信栏而不是信息流栈，否则
/// 信息流的平行视界栈里会混进私信话题（连带把栈里的"上次读到这里"分界线
/// 之类的定位逻辑也搞乱）。
///
/// 这里现取一次话题详情判断 [TopicDetail.isPrivateMessage]，并把生成的
/// instanceId 一并传给 select()——真正打开的 [TopicDetailPage] 用同一个
/// instanceId 命中 [topicDetailProvider] 的 30 秒缓存，不会二次请求。
Future<void> _openTopicOrMessageInWorkspace(
  BuildContext context,
  WidgetRef ref, {
  required int topicId,
  int? postNumber,
  String? highlightBoostUsername,
  int? initialRevisionPostNumber,
  int? initialRevisionNumber,
}) async {
  final instanceId = const Uuid().v4();
  var isPrivateMessage = false;
  try {
    final detail = await ref.read(
      topicDetailProvider(
        TopicDetailParams(topicId, instanceId: instanceId),
      ).future,
    );
    isPrivateMessage = detail.isPrivateMessage;
  } catch (e) {
    debugPrint('[通知跳转] 预取话题详情失败,按普通话题处理: $e');
  }
  if (!context.mounted) return;

  if (isPrivateMessage) {
    _openMessageInWorkspace(
      context,
      ref,
      topicId: topicId,
      postNumber: postNumber,
      instanceId: instanceId,
    );
    return;
  }

  if (!_useWorkspaceNavigation(context)) {
    _pushOnRootNavigator(
      context,
      TopicDetailPage(
        topicId: topicId,
        scrollToPostNumber: postNumber,
        instanceId: instanceId, // 命中上面预取的 topicDetailProvider 缓存
        highlightBoostUsername: highlightBoostUsername,
        initialRevisionPostNumber: initialRevisionPostNumber,
        initialRevisionNumber: initialRevisionNumber,
        autoSwitchToMasterDetail: true,
      ),
    );
    return;
  }

  ref
      .read(selectedTopicProvider.notifier)
      .select(
        topicId: topicId,
        scrollToPostNumber: postNumber,
        instanceId: instanceId,
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
        if (!_useWorkspaceNavigation(context)) {
          _pushOnRootNavigator(
            context,
            UserProfilePage(username: notification.username!),
          );
          break;
        }
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

    case NotificationType.privateMessage:
    case NotificationType.invitedToPrivateMessage:
      // 这两个类型只在"创建/受邀入私信"时发一次，能确定就是私信，不用
      // 再多一趟话题详情请求确认 archetype。
      if (notification.topicId != null) {
        _openMessageInWorkspace(
          context,
          ref,
          topicId: notification.topicId!,
          postNumber: notification.postNumber,
        );
      }
      break;

    case NotificationType.boost:
      if (notification.topicId != null) {
        _openTopicOrMessageInWorkspace(
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
        _openTopicOrMessageInWorkspace(
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
      // posted(私信内新回复)、liked、reaction 等通用类型都落在这里——
      // 通知类型本身不带"是不是私信"的信息，必须实际查一下话题。
      if (notification.topicId != null) {
        _openTopicOrMessageInWorkspace(
          context,
          ref,
          topicId: notification.topicId!,
          postNumber: notification.postNumber,
        );
      }
      break;
  }
}
