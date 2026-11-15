import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/nested_reading_position.dart';
import '../../../widgets/common/positioned_stream_list.dart';
import '../../../widgets/nested/nested_reading_scope.dart';
import '../../../models/topic.dart';
import '../../../models/pending_post.dart';
import '../../../providers/nested_topic_provider.dart';
import '../../../utils/blocked_user_filter.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/nested/nested_post_card.dart';
import '../../../widgets/post/post_item/post_item.dart';
import 'topic_detail_header.dart';
import 'shared_issue_button.dart';
import 'topic_more_topics.dart';
import 'topic_status_notices.dart';
import 'private_message_participants.dart';
import 'pending_posts_section.dart';

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
  final void Function(PendingPost pending)? onWithdrawPendingPost;
  final void Function(PendingPost pending)? onWithdrawAndEditPendingPost;
  final int? removingPrivateMessageParticipantId;
  final String? removingPrivateMessageGroupName;
  final ValueChanged<TopicUser>? onRemovePrivateMessageParticipant;
  final ValueChanged<TopicGroup>? onRemovePrivateMessageGroup;
  final VoidCallback? onInvitePrivateMessageParticipants;
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
  final NestedReadingSession? session;
  final NestedReadingPosition? resumePosition;
  final NestedReadingPosition? restorePosition;
  final int? fullTargetPostNumber;
  final bool active;
  final ValueChanged<NestedReadingPosition>? onPositionChanged;
  final VoidCallback? onResume;
  final VoidCallback? onFullTargetConsumed;
  final ValueChanged<int>? onViewportPostChanged;
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
    this.onWithdrawPendingPost,
    this.onWithdrawAndEditPendingPost,
    this.removingPrivateMessageParticipantId,
    this.removingPrivateMessageGroupName,
    this.onRemovePrivateMessageParticipant,
    this.onRemovePrivateMessageGroup,
    this.onInvitePrivateMessageParticipants,
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
    this.session,
    this.resumePosition,
    this.restorePosition,
    this.fullTargetPostNumber,
    this.active = true,
    this.onPositionChanged,
    this.onResume,
    this.onFullTargetConsumed,
    this.onViewportPostChanged,
  });

  @override
  ConsumerState<NestedPostList> createState() => _NestedPostListState();
}

class _NestedPostListState extends ConsumerState<NestedPostList> {
  late final NestedReadingSession _session;
  Map<int, bool> get _expansionState => _session.expanded;
  final NestedViewportController _viewport = NestedViewportController();
  final ListController _listController = ListController();
  Map<int, int> _postRowIndices = const {};
  HeaderAnchorHandle? _readingAnchor;
  RenderNestedPostAnchor? _anchoredPost;
  GlobalKey _contextTargetKey = GlobalKey();
  int? _scrolledToTarget;
  int? _highlightTarget;
  bool _restoring = false;
  bool _hasInteracted = false;
  int _operation = 0;
  int? _handledFullTarget;
  NestedReadingPosition? _lastPosition;
  final ValueNotifier<int?> _currentRoot = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? NestedReadingSession();
    if (_session.sort != widget.nestedState.sort) {
      _session.branches.clear();
      _session.expanded.clear();
    }
    _session.sort = widget.nestedState.sort;
    _expandContextPath();
    _viewport.onSample = _onSample;
    _listController.itemPositions.addListener(_viewport.scheduleSample);
    _viewport.onOverlaySample = (visible, position, interacted) {
      if (!widget.active) return;
      widget.onVisiblePostsChanged?.call(visible);
      if (position != null && interacted) {
        widget.onPositionChanged?.call(
          NestedReadingPosition(
            postNumber: position.postNumber,
            rootPostNumber: position.rootPostNumber,
            offset: position.offset,
            sort: widget.nestedState.sort,
            expanded: Map.of(_expansionState),
          ),
        );
      }
    };
    widget.scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.fullTargetPostNumber != null) {
        unawaited(_revealFullTarget(widget.fullTargetPostNumber!));
      } else if (widget.nestedState.contextMode) {
        unawaited(_positionContext());
      } else if (_session.position != null && _session.scrollOffset > 0) {
        unawaited(_restoreSession());
      } else {
        _viewport.scheduleSample();
      }
    });
  }

  @override
  void didUpdateWidget(covariant NestedPostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fullTargetPostNumber == null) _handledFullTarget = null;
    if (widget.nestedState.sort != oldWidget.nestedState.sort) {
      _session.branches.clear();
      _session.expanded.clear();
      _session.sort = widget.nestedState.sort;
      _scrolledToTarget = null;
    }
    if (widget.fullTargetPostNumber != null &&
        widget.fullTargetPostNumber != _handledFullTarget) {
      unawaited(_revealFullTarget(widget.fullTargetPostNumber!));
    } else if (widget.nestedState.targetPostNumber !=
            oldWidget.nestedState.targetPostNumber ||
        widget.relocateToken != oldWidget.relocateToken) {
      _scrolledToTarget = null;
      _contextTargetKey = GlobalKey();
      unawaited(_positionContext());
    }
    if (widget.active != oldWidget.active) _viewport.scheduleSample();
  }

  void _expandContextPath() {
    var node = widget.nestedState.contextChain;
    final target = widget.nestedState.targetPostNumber;
    while (node != null && node.post.postNumber != target) {
      _expansionState[node.post.postNumber] = true;
      node = node.children.firstOrNull;
    }
  }

  Future<void> _nextFrame() => WidgetsBinding.instance.endOfFrame;

  Future<void> _restoreSession() async {
    _restoring = true;
    final position = _session.position;
    if (position != null &&
        !widget.nestedState.roots.any(
          (node) => node.post.postNumber == position.rootPostNumber,
        )) {
      await _revealFullTarget(position.postNumber, desired: position);
      return;
    }
    await _nextFrame();
    if (!mounted || !widget.scrollController.hasClients) return;
    widget.scrollController.jumpTo(
      _session.scrollOffset.clamp(
        widget.scrollController.position.minScrollExtent,
        widget.scrollController.position.maxScrollExtent,
      ),
    );
    await _nextFrame();
    if (!mounted) return;
    if (position != null) {
      await _alignPost(
        position.postNumber,
        position.offset,
        rootPostNumber: position.rootPostNumber,
      );
    }
    if (!mounted) return;
    setState(() => _restoring = false);
    _viewport.scheduleSample();
  }

  Future<void> _alignPost(
    int target,
    double offset, {
    int? rootPostNumber,
  }) async {
    final operation = _operation;
    _cancelReadingAnchor();
    await _nextFrame();
    if (!mounted || operation != _operation || !_listController.isAttached) {
      return;
    }
    final root =
        rootPostNumber ??
        _viewport.find(target)?.rootPostNumber ??
        (widget.nestedState.contextMode
            ? widget.nestedState.contextChain?.post.postNumber
            : null) ??
        target;
    final index = _postRowIndices[root];
    if (index == null) return;
    // 目标分支按索引物化后，在绘制前直接定位其内部的正文锚点。
    await _listController.jumpToIndex(
      index,
      offset: offset,
      targetRectResolver: (_, item) {
        final post = _viewport.find(target);
        if (post == null) return null;
        final dy = post.localToGlobal(Offset.zero, ancestor: item).dy;
        return Rect.fromLTWH(0, dy, item.size.width, 0);
      },
    );
  }

  void _cancelReadingAnchor() {
    _readingAnchor?.cancel();
    _readingAnchor = null;
    _anchoredPost = null;
  }

  void _anchorReadingPost(int postNumber) {
    if (!_listController.isAttached ||
        !widget.scrollController.hasClients ||
        widget.scrollController.position.isScrollingNotifier.value) {
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

  Future<void> _positionContext() async {
    final target = widget.nestedState.targetPostNumber;
    if (!widget.nestedState.contextMode ||
        target == null ||
        _scrolledToTarget == target) {
      return;
    }
    final operation = ++_operation;
    _restoring = true;
    _highlightTarget = target;
    final restore = widget.restorePosition;
    if (restore != null) _expansionState.addAll(restore.expanded);
    _expandContextPath();
    await _alignPost(target, restore?.offset ?? 160);
    if (!mounted || operation != _operation) return;
    _scrolledToTarget = target;
    setState(() => _restoring = false);
    _viewport.scheduleSample();
  }

  Future<void> _revealFullTarget(
    int target, {
    NestedReadingPosition? desired,
  }) async {
    if (_handledFullTarget == target) return;
    _handledFullTarget = target;
    final operation = ++_operation;
    _restoring = true;
    try {
      if (target <= 1) {
        await _nextFrame();
        if (!mounted || !widget.scrollController.hasClients) return;
        widget.scrollController.jumpTo(0);
        if (widget.restorePosition != null) {
          await _alignPost(target, widget.restorePosition!.offset);
        }
        if (mounted) widget.onFullTargetConsumed?.call();
        return;
      }
      final notifier = ref.read(nestedTopicProvider(widget.params).notifier);
      final desiredSort = (desired ?? widget.restorePosition)?.sort;
      if (desiredSort != null && desiredSort != widget.nestedState.sort) {
        await notifier.changeSort(desiredSort);
        if (!mounted) return;
      }
      final path = await notifier.revealPost(target);
      if (!mounted || operation != _operation) return;
      for (final post in path) {
        _expansionState[post] = true;
      }
      _highlightTarget = target;
      setState(() {});
      await _nextFrame();
      if (!mounted || operation != _operation) return;
      final root = path.firstOrNull;
      final visibleRoots = BlockedUserFilter.visibleNestedNodes(
        widget.nestedState.roots,
        widget.blockedUsernames,
      );
      final index = visibleRoots.indexWhere(
        (node) => node.post.postNumber == root,
      );
      if (index < 0) throw StateError('Target branch unavailable');
      if (!mounted || operation != _operation) return;
      await _alignPost(
        target,
        (desired ?? widget.restorePosition)?.offset ?? 80,
        rootPostNumber: root,
      );
      if (mounted &&
          operation == _operation &&
          _viewport.find(target) == null) {
        throw StateError('Target body unavailable');
      }
      if (mounted) widget.onFullTargetConsumed?.call();
    } catch (_) {
      if (mounted) widget.onFullTargetConsumed?.call();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.nested_restoreFailed)),
        );
      }
    } finally {
      if (mounted && operation == _operation) {
        _restoring = false;
        setState(() {});
        _viewport.scheduleSample();
      }
    }
  }

  void _onSample(Set<int> visible, NestedReadingPosition? position) {
    if (!widget.active) {
      widget.onVisiblePostsChanged?.call({});
      return;
    }
    if (_restoring) return;
    widget.onVisiblePostsChanged?.call(visible);
    if (position == null) return;
    final saved = NestedReadingPosition(
      postNumber: position.postNumber,
      rootPostNumber: position.rootPostNumber,
      offset: position.offset,
      sort: widget.nestedState.sort,
      expanded: Map.of(_expansionState),
    );
    _lastPosition = saved;
    _anchorReadingPost(saved.postNumber);
    _currentRoot.value = saved.rootPostNumber;
    widget.onViewportPostChanged?.call(saved.postNumber);
    _session
      ..position = saved
      ..contextTarget = widget.nestedState.targetPostNumber
      ..sort = saved.sort
      ..scrollOffset = widget.scrollController.hasClients
          ? widget.scrollController.offset
          : 0;
    // 首屏不覆盖历史续读位置，只有用户真实浏览后才更新持久记录。
    if (_hasInteracted) {
      widget.onPositionChanged?.call(saved);
    }
  }

  void _onScroll() {
    _viewport.scheduleSample();
  }

  Future<void> _changeSort(String sort) async {
    try {
      await ref
          .read(nestedTopicProvider(widget.params).notifier)
          .changeSort(sort);
      if (!mounted) return;
      _session.position = null;
      _session.scrollOffset = 0;
      if (widget.scrollController.hasClients) widget.scrollController.jumpTo(0);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.nested_restoreFailed)),
        );
      }
    }
  }

  Future<void> _loadNewRoots() async {
    await ref.read(nestedTopicProvider(widget.params).notifier).loadNewRoots();
  }

  Future<void> _nextRoot() async {
    final current = _lastPosition?.rootPostNumber;
    final roots = BlockedUserFilter.visibleNestedNodes(
      widget.nestedState.roots,
      widget.blockedUsernames,
    );
    final index = roots.indexWhere((node) => node.post.postNumber == current);
    if (index < 0 && current != 1) return;
    if (index + 1 >= roots.length && widget.nestedState.hasMoreRoots) {
      await ref
          .read(nestedTopicProvider(widget.params).notifier)
          .loadMoreRoots();
      await _nextFrame();
    }
    if (!mounted) return;
    final next = BlockedUserFilter.visibleNestedNodes(
      widget.nestedState.roots,
      widget.blockedUsernames,
    ).elementAtOrNull(index + 1);
    if (next == null) return;
    if (mounted) await _alignPost(next.post.postNumber, 24);
  }

  @override
  void dispose() {
    ++_operation;
    _cancelReadingAnchor();
    _listController.itemPositions.removeListener(_viewport.scheduleSample);
    _listController.dispose();
    widget.scrollController.removeListener(_onScroll);
    _viewport.dispose();
    _currentRoot.dispose();
    super.dispose();
  }

  /// 根据设备类型计算最大嵌套深度
  int _getMaxDepth(BuildContext context) {
    return switch (Responsive.getDeviceType(context)) {
      DeviceType.mobile => 5,
      DeviceType.tablet => 7,
      DeviceType.desktop => 10,
    };
  }

  PrivateMessageParticipants _buildPrivateMessageParticipants(
    PrivateMessageParticipantsLocation location,
  ) {
    return PrivateMessageParticipants.fromDetail(
      location: location,
      detail: widget.detail,
      removingParticipantId: widget.removingPrivateMessageParticipantId,
      removingGroupName: widget.removingPrivateMessageGroupName,
      onRemoveParticipant: widget.onRemovePrivateMessageParticipant,
      onRemoveGroup: widget.onRemovePrivateMessageGroup,
      onInvite: widget.onInvitePrivateMessageParticipants,
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxDepth = _getMaxDepth(context);

    // 各帖正文通过独立几何锚点上报可见性。
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
    final contextChain = contextMode ? ns.contextChain : null;
    final p = widget.params;

    final rows = <({String key, WidgetBuilder builder})>[
      (
        key: 'header',
        builder: (context) => TopicDetailHeader(
          detail: widget.detail,
          headerKey: widget.headerKey,
          showTitle: !widget.hideHeaderTitle,
          onVoteChanged: widget.onVoteChanged,
          onNotificationLevelChanged: widget.onNotificationLevelChanged,
          onJumpToPost: widget.onJumpToPost,
        ),
      ),

      if (!contextMode &&
          widget.resumePosition != null &&
          widget.onResume != null)
        (
          key: 'resume',
          builder: (context) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('nested-resume-reading'),
                icon: const Icon(Icons.history_rounded),
                onPressed: widget.onResume,
                label: Text(
                  context.l10n.nested_resumeReading(
                    widget.resumePosition!.postNumber,
                  ),
                ),
              ),
            ),
          ),
        ),
      if (opPost != null)
        (
          key: 'op',
          builder: (context) => NestedPostAnchor(
            controller: _viewport,
            postNumber: opPost.postNumber,
            rootPostNumber: opPost.postNumber,
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
        ),

      if (opPost != null &&
          PrivateMessageParticipants.shouldShow(widget.detail))
        (
          key: 'pm-first',
          builder: (context) => _buildPrivateMessageParticipants(
            PrivateMessageParticipantsLocation.firstPost,
          ),
        ),

      (
        key: 'sort',
        builder: (context) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _SortChip(
                label: context.l10n.nested_sortTop,
                value: 'top',
                current: ns.sort,
                onTap: () => _changeSort('top'),
              ),
              _SortChip(
                label: context.l10n.nested_sortNew,
                value: 'new',
                current: ns.sort,
                onTap: () => _changeSort('new'),
              ),
              _SortChip(
                label: context.l10n.nested_sortOld,
                value: 'old',
                current: ns.sort,
                onTap: () => _changeSort('old'),
              ),
            ],
          ),
        ),
      ),

      if (contextMode && contextChain == null)
        (
          key: 'context-banner',
          builder: (context) => _buildContextBanner(context),
        ),

      if (!contextMode && ns.newRootPostIds.isNotEmpty)
        (
          key: 'new-roots',
          builder: (context) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.tonal(
              onPressed: _loadNewRoots,
              child: Text(
                context.l10n.nested_newReplies(ns.newRootPostIds.length),
              ),
            ),
          ),
        ),

      if (contextMode && contextChain != null)
        (
          key: 'context',
          builder: (context) => NestedPostCard(
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
        for (var index = 0; index < roots.length; index++)
          (
            key: 'root-${roots[index].post.id}',
            builder: (context) => NestedPostCard(
              key: ValueKey(roots[index].post.id),
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
              highlightPostNumber: _highlightTarget,
            ),
          ),

      if ((!contextMode || contextChain == null) &&
          (ns.hasMoreRoots || ns.isLoadingMore))
        (key: 'load-more', builder: _buildLoadMore),

      if (!contextMode &&
          !ns.hasMoreRoots &&
          widget.detail.pendingPosts.isNotEmpty &&
          widget.onWithdrawPendingPost != null &&
          widget.onWithdrawAndEditPendingPost != null)
        (
          key: 'pending-posts',
          builder: (context) => PendingPostsSection(
            pendingPosts: widget.detail.pendingPosts,
            onWithdraw: widget.onWithdrawPendingPost!,
            onWithdrawAndEdit: widget.onWithdrawAndEditPendingPost!,
          ),
        ),

      // 同平铺视图，根节点全部加载完后展示话题提示和推荐区。
      // context 定位模式只展示局部帖子。
      if (!contextMode && !ns.hasMoreRoots)
        (
          key: 'topic-status-notices',
          builder: (context) => TopicStatusNotices(detail: widget.detail),
        ),
      if (!contextMode && !ns.hasMoreRoots)
        (
          key: 'suggested',
          builder: (context) => MoreTopicsSection(detail: widget.detail),
        ),

      if (!ns.hasMoreRoots &&
          PrivateMessageParticipants.shouldShowAtBottom(widget.detail))
        (
          key: 'pm-bottom',
          builder: (context) => _buildPrivateMessageParticipants(
            PrivateMessageParticipantsLocation.bottom,
          ),
        ),

      (
        key: 'bottom-inset',
        builder: (context) =>
            SizedBox(height: MediaQuery.of(context).padding.bottom + 100),
      ),
    ];
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    _postRowIndices = {
      if (opPost != null) opPost.postNumber: indices['op']!,
      if (contextMode && contextChain != null)
        contextChain.post.postNumber: indices['context']!
      else
        for (final root in roots)
          root.post.postNumber: indices['root-${root.post.id}']!,
    };

    return NestedReadingScope(
      controller: _viewport,
      session: _session,
      targetBanner: contextMode ? _buildContextBanner(context) : null,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) _cancelReadingAnchor();
          if (notification is ScrollStartNotification &&
                  notification.dragDetails != null ||
              notification is UserScrollNotification &&
                  notification.direction != ScrollDirection.idle) {
            _hasInteracted = true;
            if (_restoring) {
              ++_operation;
              _listController.cancelPositioning();
              setState(() => _restoring = false);
            }
          }
          if (notification is ScrollEndNotification) _viewport.scheduleSample();
          return widget.onScrollNotification(notification);
        },
        child: Stack(
          children: [
            PositionedStreamList(
              key: _viewport.viewportKey,
              scrollController: widget.scrollController,
              listController: _listController,
              positionKey: (widget.topicId, contextMode, ns.sort),
              initialIndex: null,
              cacheExtent: Responsive.isMobile(context) ? 300 : 500,
              itemKeys: rows.map((row) => row.key).toList(),
              itemBuilder: (context, index) => rows[index].builder(context),
            ),
            if (_restoring)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
            PositionedDirectional(
              end: 16,
              bottom: 100 + MediaQuery.paddingOf(context).bottom,
              child: !contextMode && roots.isNotEmpty
                  ? ValueListenableBuilder<int?>(
                      valueListenable: _currentRoot,
                      builder: (context, current, _) {
                        final index = roots.indexWhere(
                          (node) => node.post.postNumber == current,
                        );
                        final hasNext =
                            current != null &&
                            (current == 1 || index >= 0) &&
                            (index + 1 < roots.length || ns.hasMoreRoots);
                        if (!hasNext) return const SizedBox.shrink();
                        return FloatingActionButton(
                          heroTag: null,
                          tooltip: context.l10n.nested_nextRoot,
                          onPressed: _nextRoot,
                          child: const Icon(Icons.skip_next_rounded),
                        );
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
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
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
        ),
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
                  onPressed: () =>
                      widget.onViewParentContext!(ns.topAncestorPostNumber!),
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
        decoration: ShapeDecoration(
          color: isActive
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(16),
          ),
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
