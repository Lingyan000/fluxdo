import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../../models/notification.dart';
import '../../utils/url_helper.dart';
import '../common/emoji_text.dart';
import '../common/smart_avatar.dart';
import '../common/relative_time_text.dart';
import '../user/activity_card_layout.dart';

// discourse-follow 插件的自定义 SVG 图标
const _followNewFollowerSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33 30">'
    '<path d="M23.1 29.2h1.5c.8 0 1.5-.7 1.5-1.5v-5.3h5.1c.8 0 1.5-.7 1.5-1.5v-1.5c0-.8-.7-1.5-1.5-1.5h-5.1v-5c0-.8-.7-1.5-1.5-1.5h-1.5c-.8 0-1.5.7-1.5 1.5v5h-4.7c-.8 0-1.5.7-1.5 1.5v1.5c0 .8.7 1.5 1.5 1.5h4.7v5.3c0 .8.6 1.5 1.5 1.5zM18.4 29.1v-3.9c0-.1-.1-.1-.1-.1h-2.5c-2.7 0-3.7-2.1-3.7-4V18c0-.2-.2-.2-.2-.2-1.3 0-2.6-.4-4-1h-.5c-4.1 0-7.4 3.3-7.4 7.4v1.9c0 1.7 1.4 3.1 3.1 3.1h15.2c0 .1.1 0 .1-.1z"/>'
    '<circle cx="12.5" cy="7.1" r="7.1"/>'
    '</svg>';

const _followNewTopicSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33 30">'
    '<path d="M32.6 21.6c-.6-.7-1.8-1.7-1.8-5 0-2.4-1.6-4.3-3.8-4.9-.3-1.6-2.4-1.6-2.7 0-2.2.6-3.9 2.5-3.9 4.9 0 3.3-1.2 4.3-1.8 5-.2.2-.3.5-.3.7 0 .5.4 1 1 1h12.5c.9 0 1.4-1.1.8-1.7zM20.1 29.2h-17c-1.7 0-3.1-1.4-3.1-3.1v-1.9c0-4.3 3.7-7.7 8-7.4 2.6 1.3 6 1.4 8.6.1 0 0 .1-.1.1 0 0 2.4-.5 2.8-1.2 3.5-2 2.1-.7 5.9 2.4 5.7h.8c.1 0 .1.3.1.4.1 1.1.6 1.8 1.3 2.7M25.6 29.2c1.7 0 3-1.3 3-2.9h-6c0 1.5 1.3 2.9 3 2.9zM12.3 14.2c3.9 0 7.1-3.2 7.1-7.1-.3-9.5-14-9.5-14.3 0 0 3.9 3.2 7.1 7.2 7.1z"/>'
    '</svg>';

const _followNewReplySvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33 30">'
    '<path d="M15.2 29.3H3.1c-1.7 0-3.1-1.4-3.1-3.1v-1.8C0 20.3 3.3 17 7.4 17h.5c1.3.6 2.8 1 4.4 1 .2 0 .6 0 1.2-.2 0 0 .3 0 .1.3-.8 1.5-1.1 3.2-1.1 4.8 0 2.5 1 4.7 2.7 6.3 0 0 .2.1 0 .1zM12.3 14.3c4 0 7.2-3.2 7.2-7.2S16.3 0 12.3 0 5.1 3.2 5.1 7.2s3.2 7.1 7.2 7.1zM32.4 17.1 26 11.6c-.6-.5-1.5-.1-1.5.7V15.1c-4.8.5-8.4 2.2-8.4 7.6 0 2.6 1.5 5.1 3.2 6.4.5.4 1.3-.1 1.1-.8-1.4-5 .1-7 4.1-7.5v2.4c0 .7.9 1.1 1.5.7l6.4-5.5c.4-.3.4-1 0-1.3z"/>'
    '</svg>';

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
    String? svgData;
    switch (notification.notificationType) {
      case NotificationType.following:
        svgData = _followNewFollowerSvg;
        break;
      case NotificationType.followingCreatedTopic:
        svgData = _followNewTopicSvg;
        break;
      case NotificationType.followingReplied:
        svgData = _followNewReplySvg;
        break;
      default:
        break;
    }
    if (svgData != null) {
      final si = ScalableImage.fromSvgString(
        svgData,
        warnF: (_) {},
      ).modifyTint(newTintColor: color, newTintMode: BlendMode.srcIn);
      return SizedBox(
        width: _badgeIconSize,
        height: _badgeIconSize,
        child: ScalableImageWidget(si: si),
      );
    }
    return Icon(_getNotificationIcon(), size: _badgeIconSize, color: color);
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
