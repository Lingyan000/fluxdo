import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../common/positioned_stream_list.dart';
import 'embedded_posts.dart';

/// 回复列表组件:竖线串起各条回复的头像挂在当前帖下,末端是收起按钮
class PostRepliesList extends StatelessWidget {
  final List<Post> replies;
  final bool canLoadMore;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onLoadMore;
  final void Function(int postNumber)? onJumpToPost;
  final double contentFontScale;

  const PostRepliesList({
    super.key,
    required this.replies,
    required this.canLoadMore,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onLoadMore,
    this.onJumpToPost,
    this.contentFontScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (replies.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < replies.length; i++)
            EmbeddedReplyTile(
              post: replies[i],
              first: i == 0,
              last: i == replies.length - 1,
              contentFontScale: contentFontScale,
              onTap: () => onJumpToPost?.call(replies[i].postNumber),
            ),
          Row(
            children: [
              EmbeddedReplyCollapseButton(
                onPressed: () {
                  // 底部收起:长回复区收起后保持其后的帖子不动
                  PositionedStreamList.keepTrailingEdgeOnShrink(context);
                  showRepliesNotifier.value = false;
                },
              ),
              if (canLoadMore) ...[
                const SizedBox(width: 8),
                ValueListenableBuilder<bool>(
                  valueListenable: isLoadingRepliesNotifier,
                  builder: (context, isLoadingReplies, _) {
                    return TextButton.icon(
                      onPressed: isLoadingReplies ? null : onLoadMore,
                      icon: isLoadingReplies
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Symbols.refresh_rounded, size: 16),
                      label: Text(context.l10n.post_loadMoreReplies),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
