import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/user/user_card.dart';

enum PrivateMessageParticipantsLocation { firstPost, bottom }

/// 底部面板的楼层数下限,对齐 Discourse showBottomTopicMap 的
/// posts_count > MIN_POSTS_COUNT(=3)。
const int _minPostsCountForBottomPanel = 3;

/// 胶囊内头像/群组图标半径;与移除按钮一起决定胶囊高度。
const double _avatarRadius = 14;

/// 移除按钮的点击区;不超过头像直径,免得把胶囊撑高。
const double _removeButtonSize = 28;

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
    this.topicId,
    this.topicTitle,
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
      topicId: detail.id,
      topicTitle: detail.title,
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

  /// 话题上下文,透给用户卡片的「基于话题的私信」(正文携带帖子链接)。
  final int? topicId;
  final String? topicTitle;

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
    return _buildEntry(
      context,
      key: ValueKey('pm-group-${location.name}-${group.name}'),
      // 全名只进 tooltip:胶囊统一单行,双行会让有/无副名的条目高低参差。
      tooltip: group.displayName == group.name
          ? group.name
          : '${group.name} · ${group.displayName}',
      leading: CircleAvatar(
        radius: _avatarRadius,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(
          Icons.group_rounded,
          size: 16,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
      label: group.name,
      canRemove: onRemoveGroup != null && canRemoveAllowedUsers,
      isRemoving: removingGroupName == group.name,
      removeKey: ValueKey('pm-group-${location.name}-remove-${group.name}'),
      removeTooltip: context.l10n.common_remove,
      onRemove: () => onRemoveGroup!(group),
    );
  }

  Widget _buildParticipant(BuildContext context, TopicUser participant) {
    // 权限完全信任服务端:can_remove_allowed_users 本身已含「staff 或
    // 房主(TL2+)」判定(TopicGuardian#can_remove_allowed_users?),再叠
    // 客户端 admin 门槛会把版主和非管理员房主一起挡掉。
    // 对齐 Discourse PmMapUser: canRemoveAllowedUsers || isCurrentUser。
    final isSelf = participant.id == removableSelfId;
    return _buildEntry(
      context,
      key: ValueKey('pm-participant-${location.name}-${participant.id}'),
      // 胶囊只显示昵称,@username 作为 @提及用的身份标识放进 tooltip。
      tooltip: participant.displayName == participant.username
          ? '@${participant.username}'
          : '${participant.displayName} · @${participant.username}',
      leading: SmartAvatar(
        imageUrl: participant.getAvatarUrl(size: 48),
        radius: _avatarRadius,
        fallbackText: participant.username,
      ),
      label: participant.displayName,
      canRemove:
          onRemoveParticipant != null && (canRemoveAllowedUsers || isSelf),
      isRemoving: removingParticipantId == participant.id,
      removeKey: ValueKey(
        'pm-participant-${location.name}-remove-${participant.id}',
      ),
      removeTooltip: isSelf
          ? context.l10n.common_exit
          : context.l10n.common_remove,
      onRemove: () => onRemoveParticipant!(participant),
      // 点胶囊出用户卡片,对齐官方 PmMapUser 的 trigger-user-card。
      // 群组不接:本项目没有群组页,给个点不出东西的入口更糟。
      //
      // 站点开了 hide_user_profiles_from_public 且未登录时卡片本就弹不出来
      // (showUserCard 内部会直接 return),这里同步把点击态摘掉,免得胶囊
      // 带着水波纹假装可点。
      onTap: !canShowUserCardPreview(context)
          ? null
          : (chipContext, link) {
              final box = chipContext.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              showUserCard(
                context: chipContext,
                anchorRect: box.localToGlobal(Offset.zero) & box.size,
                layerLink: link,
                username: participant.username,
                topicId: topicId,
                topicTitle: topicTitle,
                avatarFallbackUrl: participant.getAvatarUrl(size: 144),
                nameFallback: participant.name,
              );
            },
    );
  }

  /// 成员与群组共用的单行胶囊。
  ///
  /// 统一单行是为了让所有条目等高 —— 副行(@username / 群组全名)只在部分
  /// 条目上有,双行排版会让同一行胶囊高低参差。次要信息一律进 tooltip。
  Widget _buildEntry(
    BuildContext context, {
    required Key key,
    required String tooltip,
    required Widget leading,
    required String label,
    required bool canRemove,
    required bool isRemoving,
    required Key removeKey,
    required String removeTooltip,
    required VoidCallback onRemove,
    void Function(BuildContext chipContext, LayerLink link)? onTap,
  }) {
    return _PmEntryChip(
      chipKey: key,
      tooltip: tooltip,
      leading: leading,
      label: label,
      canRemove: canRemove,
      isRemoving: isRemoving,
      removeKey: removeKey,
      removeTooltip: removeTooltip,
      onRemove: onRemove,
      controlsLocked: _controlsLocked,
      onTap: onTap,
    );
  }
}

/// 单行胶囊本体。
///
/// 独立成 StatefulWidget 是因为用户卡片要锚定到胶囊上:浮层定位需要一个
/// 稳定的 LayerLink 与本条目自己的 BuildContext(见 showUserCard)。
class _PmEntryChip extends StatefulWidget {
  const _PmEntryChip({
    required this.chipKey,
    required this.tooltip,
    required this.leading,
    required this.label,
    required this.canRemove,
    required this.isRemoving,
    required this.removeKey,
    required this.removeTooltip,
    required this.onRemove,
    required this.controlsLocked,
    this.onTap,
  });

  final Key chipKey;
  final String tooltip;
  final Widget leading;
  final String label;
  final bool canRemove;
  final bool isRemoving;
  final Key removeKey;
  final String removeTooltip;
  final VoidCallback onRemove;
  final bool controlsLocked;

  /// 点击胶囊本体(不含移除按钮);回调拿到本条目的 context 与 LayerLink
  /// 用于锚定浮层。null = 不可点(群组没有可跳转的目标页)。
  final void Function(BuildContext chipContext, LayerLink link)? onTap;

  @override
  State<_PmEntryChip> createState() => _PmEntryChipState();
}

class _PmEntryChipState extends State<_PmEntryChip> {
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = widget.onTap;
    return Tooltip(
      message: widget.tooltip,
      child: CompositedTransformTarget(
        link: _link,
        child: ConstrainedBox(
          key: widget.chipKey,
          constraints: const BoxConstraints(maxWidth: 240),
          // Material + InkWell 而非 Container(decoration):水波纹要按胶囊
          // 圆角裁切,直接给 Container 加 decoration 的话涟漪会溢出圆角。
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap == null ? null : () => onTap(context, _link),
              child: Padding(
                // 右内边距分两档:带按钮时按钮自带留白,不带按钮时要自己补
                // 够,否则文字直接贴到胶囊边缘。
                padding: EdgeInsets.fromLTRB(
                  10,
                  5,
                  widget.canRemove ? 4 : 12,
                  5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    widget.leading,
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (widget.canRemove) ...[
                      const SizedBox(width: 2),
                      SizedBox.square(
                        dimension: _removeButtonSize,
                        child: widget.isRemoving
                            ? const Padding(
                                padding: EdgeInsets.all(7),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton(
                                key: widget.removeKey,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                tooltip: widget.removeTooltip,
                                // 移除/退出是常规操作,不该用 error 红的实心
                                // 图标压过头像和名字;危险语义交给确认弹窗
                                // 表达(官方同样只用一个弱化的 xmark)。
                                color: theme.colorScheme.onSurfaceVariant,
                                onPressed: widget.controlsLocked
                                    ? null
                                    : widget.onRemove,
                                icon: const Icon(Icons.close_rounded, size: 16),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
