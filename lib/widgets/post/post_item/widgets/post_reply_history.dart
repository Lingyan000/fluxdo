import 'package:material_ui/material_ui.dart';

import '../../../../models/topic.dart';
import 'embedded_posts.dart';

/// 父帖预览:当前帖头部下方按时间顺序列出父帖引用卡
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
      builder: (context, unfoldedIds, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final parent in parents)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ParentPostQuoteCard(
                post: parent,
                contentFontScale: contentFontScale,
                onTap: () => onJumpToPost?.call(parent.postNumber),
                unfolded: unfoldedIds.contains(parent.id),
                onToggleUnfold: () => _toggleUnfold(parent.id),
              ),
            ),
        ],
      ),
    );
  }
}
