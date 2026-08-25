// 本文件是 chat_channel_page.dart 的 part(私有类互引,拆物理文件
// 不拆库);新增聊天页组件按职责归档到对应 part。

part of 'chat_channel_page.dart';

/// 消息串入口卡(官方样式:参与者头像 + 最后回复者/摘要 + N 条回复)
class _ThreadEntryCard extends StatelessWidget {
  final ChatThreadRef thread;
  final VoidCallback onTap;

  const _ThreadEntryCard({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastUser = thread.lastReplyUser;
    final participants = thread.participants.take(3).toList();
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(
              children: [
                // 参与者头像叠排(缺 preview 时退化最后回复者/占位图标)
                if (participants.isNotEmpty)
                  SizedBox(
                    width: 18.0 * participants.length + 8,
                    height: 26,
                    child: Stack(
                      children: [
                        for (var i = 0; i < participants.length; i++)
                          Positioned(
                            left: i * 18.0,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.surface,
                                  width: 1.5,
                                ),
                              ),
                              child: SmartAvatar(
                                imageUrl: participants[i].getAvatarUrl(
                                  size: 48,
                                ),
                                radius: 11,
                                fallbackText: participants[i].username,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else if (lastUser != null)
                  SmartAvatar(
                    imageUrl: lastUser.getAvatarUrl(size: 48),
                    radius: 12,
                    fallbackText: lastUser.username,
                  )
                else
                  Icon(
                    Symbols.forum_rounded,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        S.current.chat_threadReplies(thread.replyCount),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (thread.lastReplyExcerpt?.isNotEmpty == true)
                        Row(
                          children: [
                            if (lastUser != null) ...[
                              Text(
                                lastUser.username,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: EmojiText(
                                chatPreviewText(
                                  context,
                                  thread.lastReplyExcerpt!,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (thread.lastReplyCreatedAt != null)
                  RelativeTimeText(
                    dateTime: thread.lastReplyCreatedAt!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// reaction 聚合 chip(官方样式:圆角方胶囊,选中=primary 淡底+描边);
/// 桌面 hover Tooltip 显示谁点的,移动长按弹名单
class _ReactionChip extends StatelessWidget {
  final ChatMessageReaction reaction;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _ReactionChip({required this.reaction, this.onTap, this.onLongPress});

  String _usersLabel(BuildContext context) {
    if (reaction.users.isEmpty) return ':${reaction.emoji}:';
    final names = reaction.users.take(6).map((u) => u.username).join('、');
    final more = reaction.count - reaction.users.take(6).length;
    return more > 0 ? context.l10n.chat_reactionUsersMore(names, more) : names;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = EmojiHandler().getEmojiUrl(reaction.emoji);
    final chip = Material(
      color: reaction.reacted
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: reaction.reacted
              ? theme.colorScheme.primary.withValues(alpha: 0.7)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (url.isEmpty)
                Text(reaction.emoji, style: const TextStyle(fontSize: 15))
              else
                Image(image: emojiImageProvider(url), width: 17, height: 17),
              const SizedBox(width: 5),
              Text(
                '${reaction.count}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: reaction.reacted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!PlatformUtils.isDesktop) return chip;
    // 桌面:hover 显示谁点的(官方同款)
    return Tooltip(
      message: _usersLabel(context),
      waitDuration: const Duration(milliseconds: 350),
      child: chip,
    );
  }
}

/// reactions 行尾的"加表情"胶囊(hover 行时出现,官方同款)
class _AddReactionChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddReactionChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Icon(
            Symbols.add_reaction_rounded,
            size: 17,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  final DateTime date;

  const _DayDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = theme.colorScheme.outlineVariant.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              TimeUtils.formatShortDate(date),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: line)),
        ],
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              context.l10n.chat_unreadDivider,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
