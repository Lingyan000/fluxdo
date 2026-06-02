import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/s.dart';
import '../../models/nested_topic.dart';
import '../../models/topic.dart';
import '../../providers/nested_topic_provider.dart';
import '../../utils/dialog_utils.dart';
import 'nested_post_card.dart';

/// 打开深层嵌套子树弹框
///
/// 当嵌套深度达到 maxDepth 时，点击"继续此主题"按钮打开此弹框，
/// 在弹框中从 depth 0 重新开始渲染子树。
void showNestedThreadSheet({
  required BuildContext context,
  required NestedNode node,
  required int topicId,
  required TopicDetail detail,
  required NestedTopicParams params,
  required int maxDepth,
  required bool isLoggedIn,
  required void Function(Post? replyToPost, {String? initialContent}) onReply,
  required void Function(Post post) onEdit,
  required void Function(int postId) onRefreshPost,
  required void Function(int postNumber) onJumpToPost,
  void Function(int postId, bool accepted)? onSolutionChanged,
}) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => _NestedThreadSheetContent(
      node: node,
      topicId: topicId,
      detail: detail,
      params: params,
      maxDepth: maxDepth,
      isLoggedIn: isLoggedIn,
      onReply: onReply,
      onEdit: onEdit,
      onRefreshPost: onRefreshPost,
      onJumpToPost: onJumpToPost,
      onSolutionChanged: onSolutionChanged,
    ),
  );
}

class _NestedThreadSheetContent extends ConsumerStatefulWidget {
  final NestedNode node;
  final int topicId;
  final TopicDetail detail;
  final NestedTopicParams params;
  final int maxDepth;
  final bool isLoggedIn;
  final void Function(Post? replyToPost, {String? initialContent}) onReply;
  final void Function(Post post) onEdit;
  final void Function(int postId) onRefreshPost;
  final void Function(int postNumber) onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;

  const _NestedThreadSheetContent({
    required this.node,
    required this.topicId,
    required this.detail,
    required this.params,
    required this.maxDepth,
    required this.isLoggedIn,
    required this.onReply,
    required this.onEdit,
    required this.onRefreshPost,
    required this.onJumpToPost,
    this.onSolutionChanged,
  });

  @override
  ConsumerState<_NestedThreadSheetContent> createState() =>
      _NestedThreadSheetContentState();
}

class _NestedThreadSheetContentState
    extends ConsumerState<_NestedThreadSheetContent> {
  late List<NestedNode> _children;
  bool _hasMore = false;
  bool _isLoadingMore = false;
  int _page = 0;
  final Map<int, bool> _expansionState = {};

  @override
  void initState() {
    super.initState();
    _children = List.from(widget.node.children);
    _hasMore = widget.node.hasMoreChildren;
    if (_children.isEmpty && widget.node.directReplyCount > 0) {
      _loadChildren();
    }
  }

  Future<void> _loadChildren() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final notifier = ref.read(nestedTopicProvider(widget.params).notifier);
      final response = await notifier.loadChildren(
        widget.node.post.postNumber,
        page: _page,
        depth: 1,
      );
      if (!mounted) return;
      setState(() {
        _children.addAll(response.children);
        _hasMore = response.hasMore;
        _page = response.page + 1;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            _buildHandle(theme),
            _buildTitleBar(context, theme),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // 子回复列表，depth 从 0 重新开始
                  for (int i = 0; i < _children.length; i++)
                    NestedPostCard(
                      node: _children[i],
                      topicId: widget.topicId,
                      detail: widget.detail,
                      params: widget.params,
                      depth: 0,
                      maxDepth: widget.maxDepth,
                      isLastChild: i == _children.length - 1 && !_hasMore,
                      isLoggedIn: widget.isLoggedIn,
                      onReply: widget.onReply,
                      onEdit: widget.onEdit,
                      onRefreshPost: widget.onRefreshPost,
                      onJumpToPost: widget.onJumpToPost,
                      onSolutionChanged: widget.onSolutionChanged,
                      expansionState: _expansionState,
                    ),
                  // 加载更多
                  if (_hasMore)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: _isLoadingMore
                          ? const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Center(
                              child: TextButton(
                                onPressed: _loadChildren,
                                child: Text(context.l10n.nested_loadMore),
                              ),
                            ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHandle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, ThemeData theme) {
    final post = widget.node.post;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '@${post.username} · ${context.l10n.nested_continueThread}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
