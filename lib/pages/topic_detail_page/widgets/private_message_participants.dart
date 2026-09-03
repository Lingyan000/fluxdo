import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../widgets/common/smart_avatar.dart';

enum PrivateMessageParticipantsLocation { firstPost, bottom }

/// 底部面板的楼层数下限,对齐 Discourse showBottomTopicMap 的
/// posts_count > MIN_POSTS_COUNT(=3)。
const int _minPostsCountForBottomPanel = 3;

/// 私信成员面板，对齐 Discourse 私信 topic map 的成员与退出入口。
class PrivateMessageParticipants extends StatelessWidget {
  const PrivateMessageParticipants({
    super.key,
    required this.location,
    required this.participants,
    required this.canRemoveAllowedUsers,
    required this.removableSelfId,
    required this.removingParticipantId,
    required this.onRemoveParticipant,
  });

  /// 从话题详情装配面板;权限位直接取 details 原字段,避免各调用点
  /// 自行叠加客户端判据(帖子流与嵌套视图两处必须同源)。
  factory PrivateMessageParticipants.fromDetail({
    required PrivateMessageParticipantsLocation location,
    required TopicDetail detail,
    required int? removingParticipantId,
    required ValueChanged<TopicUser>? onRemoveParticipant,
  }) {
    return PrivateMessageParticipants(
      key: ValueKey('pm-participants-${location.name}'),
      location: location,
      participants: detail.allowedUsers,
      canRemoveAllowedUsers: detail.canRemoveAllowedUsers,
      removableSelfId: detail.canRemoveSelfId,
      removingParticipantId: removingParticipantId,
      onRemoveParticipant: onRemoveParticipant,
    );
  }

  final PrivateMessageParticipantsLocation location;
  final List<TopicUser> participants;

  /// details.can_remove_allowed_users:可移除其他成员。
  final bool canRemoveAllowedUsers;

  /// details.can_remove_self_id:可退出私信,值恒为当前用户 id。
  final int? removableSelfId;

  final int? removingParticipantId;
  final ValueChanged<TopicUser>? onRemoveParticipant;

  /// 首楼面板门禁:私信且成员名单非空。
  static bool shouldShow(TopicDetail detail) =>
      detail.isPrivateMessage && detail.allowedUsers.isNotEmpty;

  /// 底部面板门禁:再加楼层数下限 —— 短私信首楼已经有一块,底部
  /// 不必紧跟着再堆一块一模一样的(官方短话题也只出一处 topic map)。
  static bool shouldShowAtBottom(TopicDetail detail) =>
      shouldShow(detail) && detail.postsCount > _minPostsCountForBottomPanel;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                context.l10n.topic_participants,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${participants.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final participant in participants)
                _buildParticipant(context, participant),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildParticipant(BuildContext context, TopicUser participant) {
    final theme = Theme.of(context);
    // 权限完全信任服务端:can_remove_allowed_users 本身已含「staff 或
    // 房主(TL2+)」判定(TopicGuardian#can_remove_allowed_users?),再叠
    // 客户端 admin 门槛会把版主和非管理员房主一起挡掉。
    // 对齐 Discourse PmMapUser: canRemoveAllowedUsers || isCurrentUser。
    final isSelf = participant.id == removableSelfId;
    final canRemove =
        onRemoveParticipant != null && (canRemoveAllowedUsers || isSelf);
    final isRemoving = removingParticipantId == participant.id;
    final controlsLocked = removingParticipantId != null;
    final showUsername = participant.displayName != participant.username;

    return Container(
      key: ValueKey('pm-participant-${location.name}-${participant.id}'),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SmartAvatar(
            imageUrl: participant.getAvatarUrl(size: 48),
            radius: 16,
            fallbackText: participant.username,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  participant.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
                if (showUsername)
                  Text(
                    '@${participant.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (canRemove) ...[
            const SizedBox(width: 4),
            SizedBox.square(
              dimension: 32,
              child: isRemoving
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      key: ValueKey(
                        'pm-participant-${location.name}-remove-${participant.id}',
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: isSelf
                          ? context.l10n.common_exit
                          : context.l10n.common_remove,
                      color: theme.colorScheme.error,
                      onPressed: controlsLocked
                          ? null
                          : () => onRemoveParticipant!(participant),
                      icon: Icon(
                        isSelf
                            ? Icons.logout_rounded
                            : Icons.person_remove_alt_1_rounded,
                        size: 18,
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
