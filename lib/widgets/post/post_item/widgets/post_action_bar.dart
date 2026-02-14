import 'package:flutter/material.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';

/// 帖子底部操作栏
class PostActionBar extends StatelessWidget {
  final Post post;
  final bool isGuest;
  final bool isOwnPost;
  final bool isLiking;
  final List<PostReaction> reactions;
  final PostReaction? currentUserReaction;
  final GlobalKey likeButtonKey;
  final List<Post> replies;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onToggleLike;
  final VoidCallback onShowReactionPicker;
  final VoidCallback? onReply;
  final VoidCallback onShowMoreMenu;
  final VoidCallback onToggleReplies;

  const PostActionBar({
    super.key,
    required this.post,
    required this.isGuest,
    required this.isOwnPost,
    required this.isLiking,
    required this.reactions,
    required this.currentUserReaction,
    required this.likeButtonKey,
    required this.replies,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onToggleLike,
    required this.onShowReactionPicker,
    this.onReply,
    required this.onShowMoreMenu,
    required this.onToggleReplies,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        // 回复数按钮
        if (post.replyCount > 0)
          ValueListenableBuilder<bool>(
            valueListenable: isLoadingRepliesNotifier,
            builder: (context, isLoadingReplies, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: showRepliesNotifier,
                builder: (context, showReplies, _) {
                  return GestureDetector(
                    onTap: isLoadingReplies ? null : onToggleReplies,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: showReplies
                            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: showReplies
                              ? theme.colorScheme.primary.withValues(alpha: 0.2)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoadingReplies && replies.isEmpty)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else ...[
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 15,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${post.replyCount}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: showReplies
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              showReplies ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              size: 18,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

        const Spacer(),
        if (!isGuest) ...[
          // 回应和赞
          if (!isOwnPost || reactions.isNotEmpty)
            GestureDetector(
              key: likeButtonKey,
              onTap: isOwnPost ? null : (isLiking ? null : onToggleLike),
              onLongPress: isOwnPost ? null : onShowReactionPicker,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: currentUserReaction != null
                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: currentUserReaction != null
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 回应表情预览
                    if (reactions.isNotEmpty && !(reactions.length == 1 && reactions.first.id == 'heart'))
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...reactions.take(3).map((reaction) => Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Image(
                              image: discourseImageProvider(EmojiHandler().getEmojiUrl(reaction.id)),
                              width: 16,
                              height: 16,
                              errorBuilder: (_, _, _) => const SizedBox(width: 16, height: 16),
                            ),
                          )),
                          const SizedBox(width: 6),
                        ],
                      ),

                    // 赞数量
                    if (reactions.isNotEmpty)
                      Text(
                        '${reactions.fold(0, (sum, r) => sum + r.count)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: currentUserReaction != null
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (reactions.isNotEmpty) const SizedBox(width: 6),

                    // 点赞图标/回应图标
                    if (currentUserReaction != null)
                      Image(
                        image: discourseImageProvider(EmojiHandler().getEmojiUrl(currentUserReaction!.id)),
                        width: 20,
                        height: 20,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.favorite,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    else
                      Icon(
                        Icons.favorite_border,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),

          const SizedBox(width: 8),

          // 回复按钮
          GestureDetector(
            onTap: onReply,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.reply,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '回复',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(width: 8),

        // 更多按钮
        GestureDetector(
          onTap: onShowMoreMenu,
          child: Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.more_horiz,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
