import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

import '../../l10n/s.dart';
import '../../models/nested_topic.dart';
import '../../models/nested_reading_position.dart';
import 'nested_reading_scope.dart';
import '../../models/topic.dart';
import '../../providers/nested_topic_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/blocked_user_filter.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';
import '../common/positioned_stream_list.dart';
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
  int? rootPostNumber,
  required bool isLoggedIn,
  required void Function(Post? replyToPost, {String? initialContent}) onReply,
  required void Function(Post post) onEdit,
  required void Function(int postId) onRefreshPost,
  required void Function(int postNumber) onJumpToPost,
  void Function(int postId, bool accepted)? onSolutionChanged,
  void Function(String selectedText, Post post)? onQuoteSelection,
}) {
  final reading = NestedReadingScope.maybeOf(context);
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _NestedThreadSheetContent(
      sourceReading: reading,
      rootPostNumber: rootPostNumber,
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
      onQuoteSelection: onQuoteSelection,
    ),
  );
}

class _NestedThreadSheetContent extends ConsumerStatefulWidget {
  final NestedNode node;
  final NestedReadingScope? sourceReading;
  final int? rootPostNumber;
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
  final void Function(String selectedText, Post post)? onQuoteSelection;

  const _NestedThreadSheetContent({
    required this.node,
    this.sourceReading,
    this.rootPostNumber,
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
    this.onQuoteSelection,
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
  final NestedViewportController _viewport = NestedViewportController();
  final NestedReadingSession _session = NestedReadingSession();
  final ListController _listController = ListController();
  HeaderAnchorHandle? _readingAnchor;
  RenderNestedPostAnchor? _anchoredPost;
  bool _interacted = false;

  @override
  void initState() {
    super.initState();
    widget.sourceReading?.controller.beginOverlay();
    _listController.itemPositions.addListener(_viewport.scheduleSample);
    _viewport.onSample = (visible, position) {
      if (position != null) _anchorReadingPost(position.postNumber);
      widget.sourceReading?.controller.onOverlaySample?.call(
        visible,
        position,
        _interacted,
      );
    };
    _viewport.onOverlaySample = (visible, position, interacted) => widget
        .sourceReading
        ?.controller
        .onOverlaySample
        ?.call(visible, position, interacted);
    _children = List.from(widget.node.children);
    _hasMore = widget.node.hasMoreChildren;
    if (_children.isEmpty && widget.node.directReplyCount > 0) {
      _loadChildren();
    }
  }

  @override
  void dispose() {
    widget.sourceReading?.controller.endOverlay();
    _readingAnchor?.cancel();
    _listController.itemPositions.removeListener(_viewport.scheduleSample);
    _listController.dispose();
    _viewport.dispose();
    super.dispose();
  }

  void _anchorReadingPost(int postNumber) {
    if (!_listController.isAttached ||
        _listController.scrollPosition?.isScrollingNotifier.value != false) {
      return;
    }
    final post = _viewport.find(postNumber);
    if (post == null ||
        (identical(post, _anchoredPost) && _readingAnchor?.isActive == true)) {
      return;
    }
    _anchoredPost = post;
    _readingAnchor = _listController.preserveHeader(post);
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
    final post = widget.node.post;
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    final children = BlockedUserFilter.visibleNestedNodes(
      _children,
      blockedUsernames,
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return AppSheetScaffold(
          expandToFill: true,
          showTitleDivider: true,
          contentPadding: EdgeInsets.zero,
          titleWidget: Text(
            '@${post.username} · ${context.l10n.nested_continueThread}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          child: NestedReadingScope(
            controller: _viewport,
            session: _session,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  _readingAnchor?.cancel();
                }
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _interacted = true;
                }
                _viewport.scheduleSample();
                return false;
              },
              child: PositionedStreamList(
                key: _viewport.viewportKey,
                scrollController: scrollController,
                listController: _listController,
                positionKey: widget.node.post.id,
                initialIndex: null,
                cacheExtent: 300,
                physics: const ScrollPhysics(),
                itemKeys: [
                  for (final child in children) 'post-${child.post.id}',
                  if (_hasMore) 'load-more',
                  'bottom-inset',
                ],
                itemBuilder: (context, i) {
                  if (i < children.length) {
                    return NestedPostCard(
                      key: ValueKey(children[i].post.id),
                      node: children[i],
                      rootPostNumber:
                          widget.rootPostNumber ?? widget.node.post.postNumber,
                      topicId: widget.topicId,
                      detail: widget.detail,
                      params: widget.params,
                      depth: 0,
                      maxDepth: widget.maxDepth,
                      isLastChild: i == children.length - 1 && !_hasMore,
                      isLoggedIn: widget.isLoggedIn,
                      blockedUsernames: blockedUsernames,
                      onReply: widget.onReply,
                      onEdit: widget.onEdit,
                      onRefreshPost: widget.onRefreshPost,
                      onJumpToPost: widget.onJumpToPost,
                      onSolutionChanged: widget.onSolutionChanged,
                      onQuoteSelection: widget.onQuoteSelection,
                      expansionState: _expansionState,
                    );
                  }
                  if (i == children.length && _hasMore) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: _isLoadingMore
                          ? const Center(child: LoadingSpinner(size: 20))
                          : Center(
                              child: TextButton(
                                onPressed: _loadChildren,
                                child: Text(context.l10n.nested_loadMore),
                              ),
                            ),
                    );
                  }
                  return const SizedBox(height: 32);
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
