import 'package:flutter/material.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../content/discourse_html_content/discourse_html_content.dart';

/// 回复列表组件
class PostRepliesList extends StatelessWidget {
  final List<Post> replies;
  final int replyCount;
  final bool canLoadMore;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onLoadMore;
  final void Function(int postNumber)? onJumpToPost;
  final double contentFontScale;

  const PostRepliesList({
    super.key,
    required this.replies,
    required this.replyCount,
    required this.canLoadMore,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onLoadMore,
    this.onJumpToPost,
    this.contentFontScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (replies.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部小标题
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  context.l10n.post_replyCount(replyCount),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // 已加载的回复列表
          ...replies.map((reply) {
            final avatarUrl = reply.getAvatarUrl(size: 60);
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onJumpToPost?.call(reply.postNumber),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          backgroundImage: avatarUrl.isNotEmpty
                              ? discourseImageProvider(avatarUrl)
                              : null,
                          child: avatarUrl.isEmpty
                              ? Text(reply.username[0].toUpperCase(), style: const TextStyle(fontSize: 10))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (reply.name != null && reply.name!.isNotEmpty) ? reply.name! : reply.username,
                                      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '#${reply.postNumber}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              IgnorePointer(
                                child: DiscourseHtmlContent(
                                  html: reply.cooked,
                                  textStyle: theme.textTheme.bodySmall?.copyWith(fontSize: 13 * contentFontScale, height: 1.4),
                                  compact: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),

          // 底部操作栏
          ValueListenableBuilder<bool>(
            valueListenable: isLoadingRepliesNotifier,
            builder: (context, isLoadingReplies, _) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (canLoadMore)
                    TextButton.icon(
                      onPressed: isLoadingReplies ? null : onLoadMore,
                      icon: isLoadingReplies
                          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh, size: 16),
                      label: Text(context.l10n.post_loadMoreReplies),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      showRepliesNotifier.value = false;
                    },
                    icon: Icon(Icons.expand_less, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    label: Text(context.l10n.post_collapseReplies, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
