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
    required this.groups,
    required this.canRemoveAllowedUsers,
    required this.removableSelfId,
    required this.canInvite,
    required this.removingParticipantId,
    required this.removingGroupName,
    required this.onRemoveParticipant,
    required this.onRemoveGroup,
    required this.onInvite,
  });

  /// 从话题详情装配面板;权限位直接取 details 原字段,避免各调用点
  /// 自行叠加客户端判据(帖子流与嵌套视图两处必须同源)。
  factory PrivateMessageParticipants.fromDetail({
    required PrivateMessageParticipantsLocation location,
    required TopicDetail detail,
    required int? removingParticipantId,
    required String? removingGroupName,
    required ValueChanged<TopicUser>? onRemoveParticipant,
    required ValueChanged<TopicGroup>? onRemoveGroup,
    required VoidCallback? onInvite,
  }) {
    return PrivateMessageParticipants(
      key: ValueKey('pm-participants-${location.name}'),
      location: location,
      participants: detail.allowedUsers,
      groups: detail.allowedGroups,
      canRemoveAllowedUsers: detail.canRemoveAllowedUsers,
      removableSelfId: detail.canRemoveSelfId,
      canInvite: detail.canInviteTo,
      removingParticipantId: removingParticipantId,
      removingGroupName: removingGroupName,
      onRemoveParticipant: onRemoveParticipant,
      onRemoveGroup: onRemoveGroup,
      onInvite: onInvite,
    );
  }

  final PrivateMessageParticipantsLocation location;
  final List<TopicUser> participants;

  /// details.allowed_groups:群组收件人,官方面板排在用户之前。
  final List<TopicGroup> groups;

  /// details.can_remove_allowed_users:可移除其他成员/群组。
  final bool canRemoveAllowedUsers;

  /// details.can_remove_self_id:可退出私信,值恒为当前用户 id。
  final int? removableSelfId;

  /// details.can_invite_to:可邀请新成员。
  final bool canInvite;

  final int? removingParticipantId;
  final String? removingGroupName;
  final ValueChanged<TopicUser>? onRemoveParticipant;
  final ValueChanged<TopicGroup>? onRemoveGroup;
  final VoidCallback? onInvite;

  /// 面板里有几个可展示的收件人条目(用户 + 群组)。
  int get _entryCount => participants.length + groups.length;

  /// 任一移除进行中:期间锁掉所有控件,避免并发提交。
  bool get _controlsLocked =>
      removingParticipantId != null || removingGroupName != null;

  /// 首楼面板门禁:私信且收件人名单非空(群组私信可能一个 user 都没有)。
  static bool shouldShow(TopicDetail detail) =>
      detail.isPrivateMessage &&
      (detail.allowedUsers.isNotEmpty || detail.allowedGroups.isNotEmpty);

  /// 底部面板门禁:再加楼层数下限 —— 短私信首楼已经有一块,底部
  /// 不必紧跟着再堆一块一模一样的(官方短话题也只出一处 topic map)。
  static bool shouldShowAtBottom(TopicDetail detail) =>
      shouldShow(detail) && detail.postsCount > _minPostsCountForBottomPanel;

  @override
  Widget build(BuildContext context) {
    if (_entryCount == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final showInvite = canInvite && onInvite != null;
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
                  '$_entryCount',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (showInvite) ...[
                const Spacer(),
                IconButton(
                  key: ValueKey('pm-participants-${location.name}-invite'),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: context.l10n.pm_inviteParticipants,
                  onPressed: _controlsLocked ? null : onInvite,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // 群组排在用户之前，对齐官方 private-message-map 的渲染顺序。
              for (final group in groups) _buildGroup(context, group),
              for (final participant in participants)
                _buildParticipant(context, participant),
            ],
          ),
        ],
      ),
    );
  }

  /// 群组条目:官方 PmMapUserGroup 只认 canRemoveAllowedUsers,
  /// 群组没有「退出」语义(自己不在名单里)。
  Widget _buildGroup(BuildContext context, TopicGroup group) {
    final theme = Theme.of(context);
    final canRemove = onRemoveGroup != null && canRemoveAllowedUsers;
    final isRemoving = removingGroupName == group.name;
    final showFullName = group.displayName != group.name;

    return Container(
      key: ValueKey('pm-group-${location.name}-${group.name}'),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(
              Icons.group_rounded,
              size: 16,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
                if (showFullName)
                  Text(
                    group.displayName,
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
                        'pm-group-${location.name}-remove-${group.name}',
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: context.l10n.common_remove,
                      color: theme.colorScheme.error,
                      onPressed: _controlsLocked
                          ? null
                          : () => onRemoveGroup!(group),
                      icon: const Icon(Icons.group_remove_rounded, size: 18),
                    ),
            ),
          ],
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
                      onPressed: _controlsLocked
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
