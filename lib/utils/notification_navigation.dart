import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_icons/app_icons.dart';
import '../l10n/s.dart';
import '../models/notification.dart';
import '../providers/discourse_providers.dart';
import '../pages/badge_page.dart';
import '../pages/chat/chat_message_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../services/local_notification_service.dart';
import '../utils/dialog_utils.dart';
import '../widgets/common/page_dialog.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/notification/notification_item.dart';

NavigatorState? _rootNavigator(BuildContext context) {
  return navigatorKey.currentState ??
      Navigator.of(context, rootNavigator: true);
}

/// 通知落点统一入口:大屏开「页面弹窗」(独立导航的迷你窗口,盖在
/// 当前内容上,看完即走),窄屏推全屏路由。
///
/// 曾经的方案是大屏写工作区栈 + 切 tab(与列表点击一致的双栏表现),
/// 但它要求先辨明话题 archetype 才能选栈(私信栏/信息流栈),而通知
/// payload 不带该信息,任何预取/乐观归位方案都引入延迟或跳变;私信
/// tab 还可能被用户从底栏移除,切 tab 请求静默失效。弹窗方案不进栈、
/// 不切 tab,这些分支整个消失,四个入口(快捷面板/全部通知页/系统
/// 通知/徽章等)行为完全一致。
void openNotificationPage(BuildContext context, Widget page) {
  if (MasterDetailLayout.canShowBothPanesFor(context)) {
    showPageDialog(context: context, builder: (_) => page);
  } else {
    _rootNavigator(context)?.push(MaterialPageRoute(builder: (_) => page));
  }
}

/// 通知 → 落点页面。null = 该通知没有可打开的目标(如入群申请通过)。
///
/// 话题/私信共用 TopicDetailPage,无需辨 archetype;
/// autoSwitchToMasterDetail 保持关闭 —— 通知打开的是临时查看面,中途
/// 拉宽窗口保持原样,不自动折叠进工作区栈(私信话题会折进错误的栈,
/// 这正是弹窗方案要消灭的分支)。
Widget? _notificationTargetPage(
  DiscourseNotification notification, {
  String? currentUsername,
}) {
  switch (notification.notificationType) {
    case NotificationType.inviteeAccepted:
    case NotificationType.following:
      final username = notification.username;
      if (username == null) return null;
      return UserProfilePage(username: username);

    case NotificationType.grantedBadge:
      final badgeId = notification.data.badgeId;
      if (badgeId == null) return null;
      return BadgePage(
        badgeId: badgeId,
        badgeSlug: notification.data.badgeSlug,
        username: currentUsername,
      );

    case NotificationType.membershipRequestAccepted:
      return null;

    case NotificationType.boost:
      if (notification.topicId == null) return null;
      return TopicDetailPage(
        topicId: notification.topicId!,
        scrollToPostNumber: notification.postNumber,
        highlightBoostUsername: notification.data.displayUsername,
      );

    case NotificationType.edited:
      // 帖子被编辑通知:跳转到对应话题 + 打开编辑历史 modal 到指定
      // revision。对齐网页版 `edited.js` 的 setLastEditNotificationClick。
      if (notification.topicId == null) return null;
      return TopicDetailPage(
        topicId: notification.topicId!,
        scrollToPostNumber: notification.postNumber,
        initialRevisionPostNumber: notification.postNumber,
        initialRevisionNumber: notification.data.revisionNumber,
      );

    case NotificationType.chatMention:
    case NotificationType.chatMessage:
    case NotificationType.chatInvitation:
    case NotificationType.chatGroupMention:
    case NotificationType.chatQuotedPost:
    case NotificationType.chatWatchedThread:
      // 聊天通知：打开频道并定位到具体消息
      final channelId = notification.data.chatChannelId;
      if (channelId == null) {
        if (notification.topicId == null) return null;
        return TopicDetailPage(
          topicId: notification.topicId!,
          scrollToPostNumber: notification.postNumber,
        );
      }
      return ChatMessagePage(
        channelId: channelId,
        channelTitle: notification.data.topicTitle ?? S.current.chat_title,
        targetMessageId: notification.data.chatMessageId,
      );

    default:
      // privateMessage/posted/liked/reaction 等所有话题类落点
      if (notification.topicId == null) return null;
      return TopicDetailPage(
        topicId: notification.topicId!,
        scrollToPostNumber: notification.postNumber,
      );
  }
}

/// 标记已读的副作用(快捷面板本地态 + 服务端),点击与弹窗内翻页共用
void _markNotificationRead(
  ProviderContainer container,
  DiscourseNotification notification,
) {
  if (notification.read) return;
  container
      .read(recentNotificationsProvider.notifier)
      .markAsRead(notification.id);
  container
      .read(discourseServiceProvider)
      .markNotificationRead(notification.id)
      .catchError((e) {
        debugPrint('标记通知已读失败: $e');
      });
}

/// 处理通知点击：标记已读 + 按类型跳转。快捷面板和历史列表页面共用。
///
/// [siblings] 是点击项所在的完整通知列表:大屏弹窗据此提供
/// 上一条/下一条快速切换;不传或窄屏时只打开单条。
void handleNotificationTap(
  BuildContext context,
  WidgetRef ref,
  DiscourseNotification notification, {
  List<DiscourseNotification>? siblings,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  _markNotificationRead(container, notification);

  final currentUsername = ref.read(currentUserProvider).value?.username;
  final page = _notificationTargetPage(
    notification,
    currentUsername: currentUsername,
  );
  if (page == null) return;

  if (!MasterDetailLayout.canShowBothPanesFor(context)) {
    _rootNavigator(context)?.push(MaterialPageRoute(builder: (_) => page));
    return;
  }

  // 大屏:可翻页的通知弹窗。播放列表只保留有落点的通知,
  // 上一条/下一条不会停在"点了没反应"的条目上。
  final playlist = (siblings ?? [notification])
      .where(
        (n) =>
            _notificationTargetPage(n, currentUsername: currentUsername) !=
            null,
      )
      .toList(growable: false);
  final initialIndex = playlist.indexWhere((n) => n.id == notification.id);

  showAppGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: S.current.common_close,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _NotificationPagerDialog(
        playlist: playlist,
        initialIndex: initialIndex < 0 ? 0 : initialIndex,
        container: container,
        currentUsername: currentUsername,
      );
    },
  );
}

/// 大屏通知弹窗 + 上一条/下一条翻页 + 通知列表
///
/// 切换 = 换 [PageDialogScaffold.contentKey] 让嵌套导航整体重建(上一条
/// 里点开的内链子页不残留),同时补标已读。列表顺序即通知面板顺序,
/// 「下一条」向更早的通知走。
///
/// 列表形态自适应:屏幕够宽(≥1240)时常驻左侧栏,否则顶部给列表
/// 按钮,点开后列表作为抽屉盖在内容上。
class _NotificationPagerDialog extends StatefulWidget {
  const _NotificationPagerDialog({
    required this.playlist,
    required this.initialIndex,
    required this.container,
    required this.currentUsername,
  });

  final List<DiscourseNotification> playlist;
  final int initialIndex;

  /// 弹窗生命周期长于发起方 widget(快捷面板点击后即收起销毁),
  /// 副作用统一走开弹窗时捕获的 container,不再依赖发起方的 ref
  final ProviderContainer container;
  final String? currentUsername;

  @override
  State<_NotificationPagerDialog> createState() =>
      _NotificationPagerDialogState();
}

class _NotificationPagerDialogState extends State<_NotificationPagerDialog>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;

  /// 本次弹窗会话内已补标已读的通知(播放列表是打开时的快照,provider
  /// 里的已读更新不会流回来,列表条目的未读圆点靠这份本地覆盖消隐)
  late final Set<int> _locallyRead = {widget.playlist[widget.initialIndex].id};

  /// 窄弹窗模式的列表抽屉开合
  late final AnimationController _drawerController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void dispose() {
    _drawerController.dispose();
    super.dispose();
  }

  void _goTo(int index, {bool closeDrawer = false}) {
    if (index < 0 || index >= widget.playlist.length) return;
    if (closeDrawer) _drawerController.reverse();
    if (index == _index) return;
    final notification = widget.playlist[index];
    setState(() {
      _index = index;
      _locallyRead.add(notification.id);
    });
    _markNotificationRead(widget.container, notification);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notification = widget.playlist[_index];
    final hasMultiple = widget.playlist.length > 1;
    // 常驻侧栏需要 880(内容) + 332(列表) + 页边距的空间
    final useSidebar =
        hasMultiple && MediaQuery.sizeOf(context).width >= 1240;

    final list = _NotificationPagerList(
      playlist: widget.playlist,
      currentIndex: _index,
      locallyRead: _locallyRead,
      container: widget.container,
      onSelect: (i) => _goTo(i, closeDrawer: !useSidebar),
    );

    return PageDialogScaffold(
      contentKey: ValueKey(notification.id),
      sidebar: useSidebar ? list : null,
      overlay: !useSidebar && hasMultiple ? _buildDrawer(theme, list) : null,
      topBar: [
        if (hasMultiple) ...[
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Text(
              '${_index + 1} / ${widget.playlist.length}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!useSidebar)
            pageDialogTopButton(
              tooltip: context.l10n.notification_showList,
              icon: Symbols.list_rounded,
              onPressed: () {
                if (_drawerController.isForwardOrCompleted) {
                  _drawerController.reverse();
                } else {
                  _drawerController.forward();
                }
              },
            ),
          pageDialogTopButton(
            tooltip: context.l10n.notification_previous,
            icon: Symbols.keyboard_arrow_up_rounded,
            onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
          ),
          pageDialogTopButton(
            tooltip: context.l10n.notification_next,
            icon: Symbols.keyboard_arrow_down_rounded,
            onPressed: _index < widget.playlist.length - 1
                ? () => _goTo(_index + 1)
                : null,
          ),
        ],
      ],
      builder: (_) =>
          _notificationTargetPage(
            notification,
            currentUsername: widget.currentUsername,
          ) ??
          const SizedBox.shrink(),
      // 全屏打开当前条目(播放列表已滤掉无落点通知,页面必然非 null);
      // 全屏后翻页/列表随弹窗一起退场,回来重新从通知入口进即可
      fullscreenBuilder: (_) =>
          _notificationTargetPage(
            notification,
            currentUsername: widget.currentUsername,
          ) ??
          const SizedBox.shrink(),
    );
  }

  /// 窄弹窗模式:列表抽屉从左滑入盖在内容上,点遮罩/选中条目收回
  Widget _buildDrawer(ThemeData theme, Widget list) {
    return AnimatedBuilder(
      animation: _drawerController,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_drawerController.value);
        if (t == 0) return const SizedBox.shrink();
        return Positioned.fill(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _drawerController.reverse(),
                  child: ColoredBox(
                    color: Colors.black26.withValues(alpha: 0.26 * t),
                  ),
                ),
              ),
              PositionedDirectional(
                start: (t - 1) * 340,
                top: 0,
                bottom: 0,
                width: 340,
                child: Material(
                  color: theme.colorScheme.surface,
                  elevation: 4,
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
      child: list,
    );
  }
}

/// 弹窗内的通知列表(常驻侧栏与抽屉共用):当前条目高亮,点击切换
class _NotificationPagerList extends StatefulWidget {
  const _NotificationPagerList({
    required this.playlist,
    required this.currentIndex,
    required this.locallyRead,
    required this.container,
    required this.onSelect,
  });

  final List<DiscourseNotification> playlist;
  final int currentIndex;
  final Set<int> locallyRead;
  final ProviderContainer container;
  final void Function(int index) onSelect;

  @override
  State<_NotificationPagerList> createState() => _NotificationPagerListState();
}

class _NotificationPagerListState extends State<_NotificationPagerList> {
  /// 初始定位到当前条目附近(条目高度不定,按估高粗定位即可)
  static const double _estimatedItemExtent = 88;

  late final ScrollController _scrollController = ScrollController(
    initialScrollOffset:
        (widget.currentIndex * _estimatedItemExtent - 120).clamp(
          0,
          double.infinity,
        ),
  );

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final systemAvatarTemplate = widget.container
        .read(systemUserAvatarTemplateProvider)
        .value;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.playlist.length,
      itemBuilder: (context, index) {
        var notification = widget.playlist[index];
        // 播放列表是快照,已读状态用本地覆盖修正未读圆点
        if (!notification.read &&
            widget.locallyRead.contains(notification.id)) {
          notification = notification.copyWith(read: true);
        }
        final selected = index == widget.currentIndex;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
          child: NotificationItem(
            notification: notification,
            systemAvatarTemplate: systemAvatarTemplate,
            onTap: () => widget.onSelect(index),
          ),
        );
      },
    );
  }
}
