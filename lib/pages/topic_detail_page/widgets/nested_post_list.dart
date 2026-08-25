import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../l10n/s.dart';
import '../../../models/nested_topic.dart';
import '../../../models/topic.dart';
import '../../../providers/nested_topic_provider.dart';
import '../../../utils/blocked_user_filter.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/nested/nested_post_card.dart';
import '../../../widgets/post/post_item/post_item.dart';
import 'topic_detail_header.dart';
import 'shared_issue_button.dart';
import 'topic_more_topics.dart';

/// 嵌套视图帖子列表 — 在现有 TopicDetailPage 内替换平铺帖子流
class NestedPostList extends ConsumerStatefulWidget {
  final NestedTopicState nestedState;
  final NestedTopicParams params;
  final TopicDetail detail;
  final Set<String> blockedUsernames;
  final int topicId;
  final ScrollController scrollController;
  final GlobalKey headerKey;
  final bool isLoggedIn;
  final void Function(Post? replyToPost, {String? initialContent}) onReply;
  final void Function(Post post) onEdit;
  final void Function(int postId) onRefreshPost;
  final void Function(int postNumber) onJumpToPost;
  final void Function(int, bool) onVoteChanged;
  final void Function(int count, bool userCreated)? onSharedIssueChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final void Function(String selectedText, Post post)? onQuoteSelection;
  final bool Function(ScrollNotification) onScrollNotification;
  final bool hideHeaderTitle;

  /// 可见帖子上报（走 ScreenTrack 上报链路）
  final void Function(Set<int> visiblePostNumbers)? onVisiblePostsChanged;

  /// context 定位模式:「查看完整话题」（切回根帖子列表）
  final VoidCallback? onViewFullTopic;

  /// context 定位模式:「查看更早的上下文」（祖先链被截断时,以最顶端祖先为新目标）
  final void Function(int postNumber)? onViewParentContext;

  /// 同目标重跳令牌:页内再次跳转同一楼层时递增,
  /// 触发重新滚动定位 + 高亮重播（目标未变时 provider 不重建,需显式驱动）
  final int relocateToken;
  const NestedPostList({
    super.key,
    required this.nestedState,
    required this.params,
    required this.detail,
    required this.blockedUsernames,
    required this.topicId,
    required this.scrollController,
    required this.headerKey,
    required this.isLoggedIn,
    required this.onReply,
    required this.onEdit,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onVoteChanged,
    this.onSharedIssueChanged,
    this.onNotificationLevelChanged,
    this.onSolutionChanged,
    this.onQuoteSelection,
    required this.onScrollNotification,
    this.hideHeaderTitle = false,
    this.onVisiblePostsChanged,
    this.relocateToken = 0,
    this.onViewFullTopic,
    this.onViewParentContext,
  });

  @override
  ConsumerState<NestedPostList> createState() => _NestedPostListState();
}

class _NestedPostListState extends ConsumerState<NestedPostList> {
  final Map<int, bool> _expansionState = {};

  /// 当前正在渲染的根帖子号集合（SliverList.builder 渲染时收集）
  final Set<int> _builtPostNumbers = {};

  /// context 定位:目标帖子的 key(挂在命中节点上,供 ensureVisible)。
  /// 同目标重跳时换新:KeyedSubtree 随 key 变更整棵重建,高亮渐隐动画重播。
  GlobalKey _contextTargetKey = GlobalKey();

  /// 已滚动定位过的目标楼层(避免重建时重复滚动)
  int? _scrolledToTarget;
  int _scrollAttempts = 0;
  static const _maxScrollAttempts = 20;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _scheduleScrollToTarget();
  }

  @override
  void didUpdateWidget(covariant NestedPostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nestedState.targetPostNumber !=
        oldWidget.nestedState.targetPostNumber) {
      _scheduleScrollToTarget();
    }
    // 同目标重跳:重置定位守卫并换 key(重播高亮),再跑一次定位
    if (widget.relocateToken != oldWidget.relocateToken) {
      _scrolledToTarget = null;
      _contextTargetKey = GlobalKey();
      _scheduleScrollToTarget();
    }
  }

  /// 首帧后滚动到 context 目标帖子;子树异步展开时 key 可能未挂上,重试几帧
  void _scheduleScrollToTarget() {
    final target = widget.nestedState.targetPostNumber;
    if (!widget.nestedState.contextMode ||
        target == null ||
        _scrolledToTarget == target) {
      return;
    }
    _scrollAttempts = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryScrollToTarget());
  }

  void _tryScrollToTarget() {
    if (!mounted) return;
    final target = widget.nestedState.targetPostNumber;
    if (target == null || _scrolledToTarget == target) return;

    final ctx = _contextTargetKey.currentContext;
    if (ctx != null) {
      _scrolledToTarget = target;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    } else if (_scrollAttempts < _maxScrollAttempts) {
      _scrollAttempts++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryScrollToTarget());
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    // 上报当前可见帖子
    if (_builtPostNumbers.isNotEmpty) {
      widget.onVisiblePostsChanged?.call(Set.from(_builtPostNumbers));
    }
  }

  /// 递归收集节点及其展开子节点中的所有 postNumber
  void _collectVisiblePostNumbers(NestedNode node) {
    _builtPostNumbers.add(node.post.postNumber);
    final expanded =
        _expansionState[node.post.postNumber] ?? node.children.isNotEmpty;
    if (expanded) {
      for (final child in node.children) {
        _collectVisiblePostNumbers(child);
      }
    }
  }

  /// 根据设备类型计算最大嵌套深度
  int _getMaxDepth(BuildContext context) {
    return switch (Responsive.getDeviceType(context)) {
      DeviceType.mobile => 5,
      DeviceType.tablet => 7,
      DeviceType.desktop => 10,
    };
  }

  @override
  Widget build(BuildContext context) {
    _builtPostNumbers.clear();
    final maxDepth = _getMaxDepth(context);

    // OP 也算可见
    final ns = widget.nestedState;
    final contextMode = ns.contextMode;
    final opPost =
        ns.opPost != null &&
            !BlockedUserFilter.isBlockedUsername(
              ns.opPost!.username,
              widget.blockedUsernames,
            )
        ? ns.opPost
        : null;
    final roots = BlockedUserFilter.visibleNestedNodes(
      ns.roots,
      widget.blockedUsernames,
    );
    if (opPost != null) _builtPostNumbers.add(opPost.postNumber);
    final contextChain = contextMode ? ns.contextChain : null;
    if (contextChain != null) _collectVisiblePostNumbers(contextChain);
    final p = widget.params;

    return NotificationListener<ScrollNotification>(
      onNotification: widget.onScrollNotification,
      child: CustomScrollView(
        controller: widget.scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: TopicDetailHeader(
              detail: widget.detail,
              headerKey: widget.headerKey,
              showTitle: !widget.hideHeaderTitle,
              onVoteChanged: widget.onVoteChanged,
              onNotificationLevelChanged: widget.onNotificationLevelChanged,
              onJumpToPost: widget.onJumpToPost,
            ),
          ),

          if (opPost != null)
            SliverToBoxAdapter(
              child: PostItem(
                post: opPost,
                topicId: widget.topicId,
                categoryId: widget.detail.categoryId,
                isTopicOwner: true,
                topicHasAcceptedAnswer: widget.detail.hasAcceptedAnswer,
                acceptedAnswers: widget.detail.acceptedAnswers,
                onReply: widget.isLoggedIn
                    ? ({initialContent}) =>
                          widget.onReply(null, initialContent: initialContent)
                    : null,
                onMentionUser: widget.isLoggedIn
                    ? (u) => widget.onReply(null, initialContent: '@$u ')
                    : null,
                onEdit: widget.isLoggedIn && ns.opPost!.canEdit
                    ? () => widget.onEdit(ns.opPost!)
                    : null,
                onRefreshPost: widget.onRefreshPost,
                onJumpToPost: widget.onJumpToPost,
                onSolutionChanged: widget.onSolutionChanged,
                onQuoteSelection: widget.onQuoteSelection,
                topicTitle: widget.detail.title,
                isPrivateMessageTopic: widget.detail.isPrivateMessage,
                isPmWithNonHumanUser: widget.detail.pmWithNonHumanUser,
                hideRepliesButton: true,
                opTopSlot: widget.detail.sharedIssueVisible
                    ? SharedIssueButton(
                        topic: widget.detail,
                        onChanged: widget.onSharedIssueChanged,
                      )
                    : null,
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _SortChip(
                    label: context.l10n.nested_sortTop,
                    value: 'top',
                    current: ns.sort,
                    onTap: () => ref
                        .read(nestedTopicProvider(p).notifier)
                        .changeSort('top'),
                  ),
                  const SizedBox(width: 6),
                  _SortChip(
                    label: context.l10n.nested_sortNew,
                    value: 'new',
                    current: ns.sort,
                    onTap: () => ref
                        .read(nestedTopicProvider(p).notifier)
                        .changeSort('new'),
                  ),
                  const SizedBox(width: 6),
                  _SortChip(
                    label: context.l10n.nested_sortOld,
                    value: 'old',
                    current: ns.sort,
                    onTap: () => ref
                        .read(nestedTopicProvider(p).notifier)
                        .changeSort('old'),
                  ),
                ],
              ),
            ),
          ),

          if (contextMode)
            SliverToBoxAdapter(child: _buildContextBanner(context)),

          if (!contextMode && ns.newRootPostIds.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: FilledButton.tonal(
                  onPressed: () =>
                      ref.read(nestedTopicProvider(p).notifier).loadNewRoots(),
                  child: Text(
                    context.l10n.nested_newReplies(ns.newRootPostIds.length),
                  ),
                ),
              ),
            ),

          if (contextMode && contextChain != null)
            SliverToBoxAdapter(
              child: NestedPostCard(
                node: contextChain,
                topicId: widget.topicId,
                detail: widget.detail,
                params: p,
                depth: 0,
                maxDepth: maxDepth,
                isLastChild: true,
                isLoggedIn: widget.isLoggedIn,
                blockedUsernames: widget.blockedUsernames,
                onReply: widget.onReply,
                onEdit: widget.onEdit,
                onRefreshPost: widget.onRefreshPost,
                onJumpToPost: widget.onJumpToPost,
                onSolutionChanged: widget.onSolutionChanged,
                onQuoteSelection: widget.onQuoteSelection,
                expansionState: _expansionState,
                highlightPostNumber: ns.targetPostNumber,
                highlightKey: _contextTargetKey,
              ),
            )
          else
            SliverList.builder(
              itemCount:
                  roots.length + (ns.hasMoreRoots || ns.isLoadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= roots.length) {
                  return _buildLoadMore(context);
                }
                // 收集可见帖子号（含子节点）
                _collectVisiblePostNumbers(roots[index]);
                return NestedPostCard(
                  node: roots[index],
                  topicId: widget.topicId,
                  detail: widget.detail,
                  params: p,
                  depth: 0,
                  maxDepth: maxDepth,
                  isLastChild: index == roots.length - 1,
                  isLoggedIn: widget.isLoggedIn,
                  blockedUsernames: widget.blockedUsernames,
                  onReply: widget.onReply,
                  onEdit: widget.onEdit,
                  onRefreshPost: widget.onRefreshPost,
                  onJumpToPost: widget.onJumpToPost,
                  onSolutionChanged: widget.onSolutionChanged,
                  onQuoteSelection: widget.onQuoteSelection,
                  expansionState: _expansionState,
                );
              },
            ),

          // 帖子流末尾的推荐区(同平铺视图,根节点全部加载完才出现;
          // context 定位模式只展示局部,不放推荐区)
          if (!contextMode && !ns.hasMoreRoots)
            SliverToBoxAdapter(
              child: MoreTopicsSection(detail: widget.detail),
            ),

          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.of(context).padding.bottom + 100,
            ),
          ),
        ],
      ),
    );
  }

  /// context 定位模式的提示条:正在查看部分回复 + 返回完整话题/查看更早上下文
  Widget _buildContextBanner(BuildContext context) {
    final theme = Theme.of(context);
    final ns = widget.nestedState;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.account_tree_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.nested_contextBanner,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              if (widget.onViewFullTopic != null)
                ActionChip(
                  avatar: const Icon(Symbols.arrow_back_rounded, size: 16),
                  label: Text(context.l10n.nested_contextViewFullTopic),
                  onPressed: widget.onViewFullTopic,
                ),
              if (ns.ancestorsTruncated &&
                  ns.topAncestorPostNumber != null &&
                  widget.onViewParentContext != null)
                ActionChip(
                  avatar: const Icon(Symbols.arrow_upward_rounded, size: 16),
                  label: Text(context.l10n.nested_contextViewParent),
                  onPressed: () => widget.onViewParentContext!(
                    ns.topAncestorPostNumber!,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMore(BuildContext context) {
    final ns = widget.nestedState;
    final p = widget.params;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ns.isLoadingMore
          ? const Center(child: LoadingSpinner())
          : Center(
              child: TextButton(
                onPressed: () =>
                    ref.read(nestedTopicProvider(p).notifier).loadMoreRoots(),
                child: Text(context.l10n.nested_loadMore),
              ),
            ),
    );
  }
}

/// 排序 Chip
class _SortChip extends StatelessWidget {
  final String label;
  final String value;
  final String current;
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.value,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = value == current;
    return GestureDetector(
      onTap: isActive ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
