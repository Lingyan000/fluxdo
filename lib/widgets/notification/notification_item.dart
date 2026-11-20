import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../models/notification.dart';
import '../../utils/url_helper.dart';
import '../common/emoji_text.dart';
import '../common/smart_avatar.dart';
import '../common/relative_time_text.dart';
import '../user/activity_card_layout.dart';

/// 通知列表项：快捷面板和大屏通知弹窗的列表共用，内容与通知页卡片一致
class NotificationItem extends StatelessWidget {
  final DiscourseNotification notification;
  final String? systemAvatarTemplate;
  final VoidCallback onTap;
  final bool showTopDivider;
  final bool selected;

  const NotificationItem({
    super.key,
    required this.notification,
    this.systemAvatarTemplate,
    required this.onTap,
    this.showTopDivider = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selectedAccent = context.emphasis.selected;
    final unread = !notification.read;
    final backgroundColor = selected
        ? selectedAccent.withValues(alpha: 0.12)
        : unread
        ? selectedAccent.withValues(alpha: 0.055)
        : Colors.transparent;

    return Ink(
      color: backgroundColor,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showTopDivider)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 64, end: 16),
                child: SizedBox(
                  height: 0.6,
                  width: double.infinity,
                  child: ColoredBox(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.65),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: NotificationContent(
                notification: notification,
                systemAvatarTemplate: systemAvatarTemplate,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 通知内容：有次行话题时首行为紧凑元信息、次行话题为主视觉；
/// 单行通知则首行直接承载正文尺度。未读突出对比度与字重，已读退后。
class NotificationContent extends StatelessWidget {
  const NotificationContent({
    super.key,
    required this.notification,
    this.systemAvatarTemplate,
  });

  final DiscourseNotification notification;
  final String? systemAvatarTemplate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final secondary = colorScheme.onSurfaceVariant;
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: secondary,
      height: 1.4,
    );
    final unread = !notification.read;
    final title = notification.title;
    final description = notification.description;
    // 描述只是类型名时（关注、徽章等），标题本身就是完整的一句话，
    // 提为首行，不再拆成「类型名 + 句子」两行
    final labelOnly = description == notification.notificationType.label;
    final headline = labelOnly ? title : description;
    final detail = labelOnly || title == description ? '' : title;
    final hasDetail = detail.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NotificationAvatar(
          notification: notification,
          systemAvatarTemplate: systemAvatarTemplate,
          radius: 18,
        ),
        const SizedBox(width: 12),
        Expanded(
          // 头像顶部与首行顶部对齐，行数多少都不改变头像位置
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ActivityCardHeader(
                metadata: _ActionLine(
                  text: headline,
                  actorName: notification.actorName,
                  unread: unread,
                  compact: hasDetail,
                ),
                timestamp: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: RelativeTimeText(
                        dateTime: notification.createdAt,
                        style: metaStyle,
                      ),
                    ),
                    if (unread) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: context.emphasis.selected,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasDetail) ...[
                const SizedBox(height: 4),
                EmojiText(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: unread ? colorScheme.onSurface : secondary,
                    fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 动作行：有次行话题时收为 13sp 辅助层，已读时收弱动作者字重与对比度，
/// 避免满屏已读时重复用户名抢走话题标题的视觉重心。
class _ActionLine extends StatelessWidget {
  const _ActionLine({
    required this.text,
    required this.actorName,
    required this.unread,
    required this.compact,
  });

  final String text;
  final String actorName;
  final bool unread;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bodyMedium = theme.textTheme.bodyMedium;
    final fontSize = compact
        ? (bodyMedium?.fontSize ?? 14) - 1
        : (bodyMedium?.fontSize ?? 14);
    final base = bodyMedium?.copyWith(
      fontSize: fontSize,
      color: !compact && unread ? cs.onSurface : cs.onSurfaceVariant,
      fontWeight: !compact && unread ? FontWeight.w500 : FontWeight.w400,
      height: compact ? 1.4 : 1.45,
    );
    final nameStyle = base?.copyWith(
      color: unread ? cs.onSurface : cs.onSurface.withValues(alpha: 0.78),
      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
    );
    final start = actorName.isEmpty ? -1 : text.indexOf(actorName);
    final spans = start < 0
        ? EmojiText.buildEmojiSpans(context, text, base)
        : [
            ...EmojiText.buildEmojiSpans(
              context,
              text.substring(0, start),
              base,
            ),
            TextSpan(text: actorName, style: nameStyle),
            ...EmojiText.buildEmojiSpans(
              context,
              text.substring(start + actorName.length),
              base,
            ),
          ];
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: base,
    );
  }
}

/// 通知头像：无动作用户时用系统用户头像，右下角挂通知类型小角标。
/// 头像贴齐布局边缘，角标悬出头像轮廓，不遮挡面部。
class NotificationAvatar extends StatelessWidget {
  static const double _badgeIconSize = 12;

  final DiscourseNotification notification;
  final String? systemAvatarTemplate;
  final double radius;

  const NotificationAvatar({
    super.key,
    required this.notification,
    this.systemAvatarTemplate,
    this.radius = 18,
  });

  IconData _getNotificationIcon() {
    switch (notification.notificationType) {
      case NotificationType.mentioned:
        return Symbols.alternate_email_rounded;
      case NotificationType.replied:
        return Symbols.reply_rounded;
      case NotificationType.quoted:
        return Symbols.format_quote_rounded;
      case NotificationType.liked:
      case NotificationType.likedConsolidated:
        return Symbols.favorite_rounded;
      case NotificationType.reaction:
        return Symbols.add_reaction_rounded;
      case NotificationType.privateMessage:
      case NotificationType.invitedToPrivateMessage:
        return Symbols.mail_rounded;
      case NotificationType.posted:
        return Symbols.post_add_rounded;
      case NotificationType.grantedBadge:
        return Symbols.military_tech_rounded;
      case NotificationType.linked:
        return Symbols.link_rounded;
      case NotificationType.bookmarkReminder:
        return Symbols.bookmark_rounded;
      case NotificationType.groupMentioned:
        return Symbols.group_rounded;
      case NotificationType.watchingFirstPost:
        return Symbols.visibility_rounded;
      case NotificationType.following:
      case NotificationType.followingCreatedTopic:
      case NotificationType.followingReplied:
        return Symbols.person_add_rounded;
      case NotificationType.watchingCategoryOrTag:
        return Symbols.label_rounded;
      case NotificationType.newFeatures:
        return Symbols.new_releases_rounded;
      case NotificationType.adminProblems:
        return Symbols.warning_rounded;
      case NotificationType.linkedConsolidated:
        return Symbols.link_rounded;
      case NotificationType.chatWatchedThread:
        return Symbols.chat_bubble_rounded;
      case NotificationType.invitedToTopic:
        return Symbols.mail_rounded;
      case NotificationType.inviteeAccepted:
        return Symbols.check_circle_rounded;
      case NotificationType.movedPost:
        return Symbols.drive_file_move_rounded;
      case NotificationType.topicReminder:
        return Symbols.alarm_rounded;
      case NotificationType.eventReminder:
      case NotificationType.eventInvitation:
        return Symbols.event_rounded;
      case NotificationType.chatMention:
      case NotificationType.chatMessage:
      case NotificationType.chatInvitation:
      case NotificationType.chatGroupMention:
      case NotificationType.chatQuotedPost:
        return Symbols.chat_rounded;
      case NotificationType.boost:
        return Symbols.rocket_launch_rounded;
      case NotificationType.assignedTopic:
        return Symbols.assignment_rounded;
      case NotificationType.questionAnswerUserCommented:
        return Symbols.question_answer_rounded;
      case NotificationType.circlesActivity:
        return Symbols.groups_rounded;
      default:
        return Symbols.notifications_rounded;
    }
  }

  /// 获取头像 URL，无 acting_user 时使用系统用户头像
  String? _getAvatarUrl() {
    final url = notification.getAvatarUrl();
    if (url.isNotEmpty) return url;
    if (systemAvatarTemplate != null && systemAvatarTemplate!.isNotEmpty) {
      return UrlHelper.resolveUrlWithCdn(systemAvatarTemplate!);
    }
    return null;
  }

  /// 构建角标图标，follow 类型使用 SVG，其他使用 Material Icon
  Widget _buildBadgeIcon(Color color) {
    final asset = switch (notification.notificationType) {
      NotificationType.following => 'assets/icons/follow_new_follower.svg',
      NotificationType.followingCreatedTopic =>
        'assets/icons/follow_new_topic.svg',
      NotificationType.followingReplied => 'assets/icons/follow_new_reply.svg',
      _ => null,
    };
    if (asset == null) {
      return Icon(_getNotificationIcon(), size: _badgeIconSize, color: color);
    }
    return SizedBox.square(
      dimension: _badgeIconSize,
      child: AppSvgAsset(asset, tint: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final selected = context.emphasis.selected;
    // 统一走主题单色体系（未读用柔和强调底，已读退回中性容器色），避免杂色角标干扰视线
    final badgeBackground = notification.read
        ? colorScheme.surfaceContainerHigh
        : Color.alphaBlend(
            selected.withValues(alpha: isDark ? 0.22 : 0.14),
            colorScheme.surfaceContainerLow,
          );
    final badgeForeground = notification.read
        ? colorScheme.onSurfaceVariant
        : selected;
    final extent = radius * 2;
    return SizedBox(
      width: extent,
      height: extent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Align(
            alignment: Alignment.center,
            child: SmartAvatar(
              imageUrl: _getAvatarUrl(),
              radius: radius,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ),
          Positioned(
            bottom: -3,
            right: -3,
            child: Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                color: badgeBackground,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.surface, width: 1.5),
              ),
              child: _buildBadgeIcon(badgeForeground),
            ),
          ),
        ],
      ),
    );
  }
}
