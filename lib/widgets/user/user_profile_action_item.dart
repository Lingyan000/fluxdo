import 'package:flutter/material.dart';
import '../../models/user_action.dart';
import '../../utils/time_utils.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';

/// 用户动态列表项
class UserActionItem extends StatelessWidget {
  final UserAction action;

  const UserActionItem({super.key, required this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: action.topicId,
              scrollToPostNumber: action.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：动作类型和时间
              Row(
                children: [
                  Icon(
                    _getActionIcon(action.actionType),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getActionLabel(action.actionType),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (action.actingAt != null)
                    Text(
                      TimeUtils.formatRelativeTime(action.actingAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              
              // 标题
              Text(
                action.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              
              // 摘要
              if (action.excerpt != null && action.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  action.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _getActionIcon(int? type) {
    switch (type) {
      case UserActionType.like:
        return Icons.favorite_rounded;
      case UserActionType.wasLiked:
        return Icons.favorite_border_rounded;
      case UserActionType.newTopic:
        return Icons.article_rounded;
      case UserActionType.reply:
        return Icons.chat_bubble_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  String _getActionLabel(int? type) {
    switch (type) {
      case UserActionType.like:
        return '点赞';
      case UserActionType.wasLiked:
        return '被赞';
      case UserActionType.newTopic:
        return '发布了话题';
      case UserActionType.reply:
        return '回复了';
      default:
        return '动态';
    }
  }
}

/// 用户回应列表项
class UserReactionItem extends StatelessWidget {
  final UserReaction reaction;

  const UserReactionItem({super.key, required this.reaction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emojiUrl = reaction.reactionValue != null
        ? EmojiHandler().getEmojiUrl(reaction.reactionValue!)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: reaction.topicId,
              scrollToPostNumber: reaction.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：回应 emoji 和时间
              Row(
                children: [
                  if (emojiUrl != null)
                    Image(
                      image: discourseImageProvider(emojiUrl),
                      width: 20,
                      height: 20,
                      errorBuilder: (_, _, _) => const Icon(Icons.emoji_emotions, size: 20),
                    )
                  else
                    const Icon(Icons.emoji_emotions, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '回应了',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (reaction.createdAt != null)
                    Text(
                      TimeUtils.formatRelativeTime(reaction.createdAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 话题标题
              if (reaction.topicTitle != null && reaction.topicTitle!.isNotEmpty)
                Text(
                  reaction.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),

              // 帖子内容摘要
              if (reaction.excerpt != null && reaction.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reaction.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

}
