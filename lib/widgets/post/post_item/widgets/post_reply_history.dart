import 'package:material_ui/material_ui.dart';

import '../../../../models/topic.dart';
import 'embedded_posts.dart';

/// 父帖预览:当前帖头部下方按时间顺序列出父帖卡,多层父帖成一组分段卡片
class PostReplyHistory extends StatelessWidget {
  final List<Post>? replyHistory;

  /// 已就地展开全文的父帖 id
  final ValueNotifier<Set<int>> unfoldedPostIdsNotifier;
  final void Function(int postNumber)? onJumpToPost;
  final double contentFontScale;

  const PostReplyHistory({
    super.key,
    required this.replyHistory,
    required this.unfoldedPostIdsNotifier,
    this.onJumpToPost,
    this.contentFontScale = 1.0,
  });

  void _toggleUnfold(int postId) {
    final current = unfoldedPostIdsNotifier.value;
    unfoldedPostIdsNotifier.value = current.contains(postId)
        ? ({...current}..remove(postId))
        : {...current, postId};
  }

  @override
  Widget build(BuildContext context) {
    final parents = replyHistory;
    if (parents == null || parents.isEmpty) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<Set<int>>(
      valueListenable: unfoldedPostIdsNotifier,
      builder: (context, unfoldedIds, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < parents.length; i++)
              ParentPostCard(
                post: parents[i],
                index: i,
                count: parents.length,
                contentFontScale: contentFontScale,
                onTap: () => onJumpToPost?.call(parents[i].postNumber),
                unfolded: unfoldedIds.contains(parents[i].id),
                onToggleUnfold: () => _toggleUnfold(parents[i].id),
              ),
          ],
        ),
      ),
    );
  }
}
