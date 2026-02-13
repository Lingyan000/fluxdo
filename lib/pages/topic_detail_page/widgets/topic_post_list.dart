import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../../../models/topic.dart';
import '../../../providers/message_bus_providers.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/post/post_item/post_item.dart';
import '../../../widgets/post/post_item_skeleton.dart';
import 'topic_detail_header.dart';
import 'typing_indicator.dart';

/// 话题帖子列表
/// 负责构建 CustomScrollView 及其 Slivers
///
/// 每个帖子独立生成一个 SliverToBoxAdapter，实现帖子级虚拟化：
/// Flutter 只构建视口附近的帖子，远离视口的帖子不会被构建。
/// 长帖子内部的 HTML 分块由 ChunkedHtmlContent 的 Column + SelectionArea 处理，
/// 保留跨块文本选择能力。
class TopicPostList extends StatefulWidget {
  final TopicDetail detail;
  final AutoScrollController scrollController;
  final GlobalKey centerKey;
  final GlobalKey headerKey;
  final int? highlightPostNumber;
  final List<TypingUser> typingUsers;
  final bool isLoggedIn;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
  final bool isLoadingPrevious;
  final bool isLoadingMore;
  final int centerPostIndex;
  final int? dividerPostIndex;
  final void Function(int postNumber) onFirstVisiblePostChanged;
  final void Function(Set<int> visiblePostNumbers)? onVisiblePostsChanged;
  final void Function(int postNumber) onJumpToPost;
  final void Function(Post? replyToPost) onReply;
  final void Function(Post post) onEdit;
  final void Function(Post post)? onShareAsImage;
  final void Function(int postId) onRefreshPost;
  final void Function(int, bool) onVoteChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool Function(ScrollNotification) onScrollNotification;

  const TopicPostList({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.centerKey,
    required this.headerKey,
    required this.highlightPostNumber,
    required this.typingUsers,
    required this.isLoggedIn,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.isLoadingPrevious,
    required this.isLoadingMore,
    required this.centerPostIndex,
    required this.dividerPostIndex,
    required this.onFirstVisiblePostChanged,
    this.onVisiblePostsChanged,
    required this.onJumpToPost,
    required this.onReply,
    required this.onEdit,
    this.onShareAsImage,
    required this.onRefreshPost,
    required this.onVoteChanged,
    this.onNotificationLevelChanged,
    this.onSolutionChanged,
    required this.onScrollNotification,
  });

  @override
  State<TopicPostList> createState() => _TopicPostListState();
}

class _TopicPostListState extends State<TopicPostList> {
  int? _lastReportedPostNumber;
  bool _isThrottled = false;

  // 便捷 getter，简化 widget.xxx 访问
  TopicDetail get detail => widget.detail;
  AutoScrollController get scrollController => widget.scrollController;
  GlobalKey get centerKey => widget.centerKey;
  GlobalKey get headerKey => widget.headerKey;
  int? get highlightPostNumber => widget.highlightPostNumber;
  List<TypingUser> get typingUsers => widget.typingUsers;
  bool get isLoggedIn => widget.isLoggedIn;
  bool get hasMoreBefore => widget.hasMoreBefore;
  bool get hasMoreAfter => widget.hasMoreAfter;
  bool get isLoadingPrevious => widget.isLoadingPrevious;
  bool get isLoadingMore => widget.isLoadingMore;
  int get centerPostIndex => widget.centerPostIndex;
  int? get dividerPostIndex => widget.dividerPostIndex;
  void Function(int postNumber) get onJumpToPost => widget.onJumpToPost;
  void Function(Post? replyToPost) get onReply => widget.onReply;
  void Function(Post post) get onEdit => widget.onEdit;
  void Function(Post post)? get onShareAsImage => widget.onShareAsImage;
  void Function(int postId) get onRefreshPost => widget.onRefreshPost;
  void Function(int, bool) get onVoteChanged => widget.onVoteChanged;
  void Function(TopicNotificationLevel)? get onNotificationLevelChanged => widget.onNotificationLevelChanged;
  void Function(int postId, bool accepted)? get onSolutionChanged => widget.onSolutionChanged;
  bool Function(ScrollNotification) get onScrollNotification => widget.onScrollNotification;
  void Function(Set<int> visiblePostNumbers)? get onVisiblePostsChanged => widget.onVisiblePostsChanged;

  /// 检测第一个可见帖子（通过 AutoScrollController 的 tagMap）
  void _updateFirstVisiblePost() {
    final posts = detail.postStream.posts;
    if (posts.isEmpty) return;

    // 使用 AutoScrollController 的 tagMap 来确定可见帖子
    final tagMap = scrollController.tagMap;
    if (tagMap.isEmpty) return;

    // 获取视口高度
    if (!scrollController.hasClients) return;
    final viewportHeight = scrollController.position.viewportDimension;

    // 获取顶部栏高度（AppBar + 状态栏）
    final topBarHeight = kToolbarHeight + MediaQuery.of(context).padding.top;

    // 找到第一个在视口顶部附近的帖子，同时收集所有可见帖子
    int? firstVisiblePostIndex;
    double bestOffset = double.infinity;
    final visiblePostNumbers = <int>{};

    for (final entry in tagMap.entries) {
      final postIndex = entry.key;
      if (postIndex >= posts.length) continue;

      final tagState = entry.value;
      final ctx = tagState.context;
      if (!ctx.mounted) continue;

      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;

      // 获取帖子顶部相对于屏幕的位置
      final globalPosition = renderBox.localToGlobal(Offset.zero);
      final topY = globalPosition.dy;

      // 相对于可见区域顶部的位置（减去顶部栏高度）
      final relativeTopY = topY - topBarHeight;

      // 帖子在可见区域内（考虑顶部栏遮挡）
      if (topY < viewportHeight && topY > topBarHeight - renderBox.size.height) {
        // 添加到可见帖子集合
        visiblePostNumbers.add(posts[postIndex].postNumber);

        // 找到最靠近可见区域顶部（或刚超过顶部）的帖子
        if (relativeTopY <= 0 && relativeTopY.abs() < bestOffset) {
          bestOffset = relativeTopY.abs();
          firstVisiblePostIndex = postIndex;
        } else if (firstVisiblePostIndex == null && relativeTopY > 0) {
          // 没有帖子超过顶部，取最靠近顶部的
          if (relativeTopY < bestOffset) {
            bestOffset = relativeTopY;
            firstVisiblePostIndex = postIndex;
          }
        }
      }
    }

    // 通知可见帖子变化（用于 screenTrack）
    if (visiblePostNumbers.isNotEmpty) {
      onVisiblePostsChanged?.call(visiblePostNumbers);
    }

    if (firstVisiblePostIndex != null) {
      int reportPostNumber = posts[firstVisiblePostIndex].postNumber;

      // 修复楼层显示 bug：滑到底部且没有更多帖子时，报告最后一个可见帖子
      if (_isAtBottom() && !hasMoreAfter && visiblePostNumbers.isNotEmpty) {
        reportPostNumber = visiblePostNumbers.reduce((a, b) => a > b ? a : b);
      }

      // 防止重复报告相同的帖子
      if (reportPostNumber != _lastReportedPostNumber) {
        _lastReportedPostNumber = reportPostNumber;
        widget.onFirstVisiblePostChanged(reportPostNumber);
      }
    }
  }

  /// 判断是否滚动到了底部
  bool _isAtBottom() {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    // 允许 1px 误差
    return position.pixels >= position.maxScrollExtent - 1;
  }

  /// 处理滚动通知，同时更新可见帖子
  bool _handleScrollNotification(ScrollNotification notification) {
    // 先调用原有的滚动通知处理
    final result = onScrollNotification(notification);

    // 在滚动更新时检测可见帖子（节流 150ms，减少滚动时的计算开销）
    if (notification is ScrollUpdateNotification && !_isThrottled) {
      _isThrottled = true;
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          _isThrottled = false;
          _updateFirstVisiblePost();
        }
      });
    }

    return result;
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapContent(BuildContext context, Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;

    final loadMoreSkeletonCount = calculateSkeletonCount(
      MediaQuery.of(context).size.height * 0.4,
      minCount: 2,
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: CustomScrollView(
          controller: scrollController,
          center: centerKey,
          cacheExtent: 1500,
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
          // 向上加载骨架屏
          if (hasMoreBefore && isLoadingPrevious)
            LoadingSkeletonSliver(
              itemCount: loadMoreSkeletonCount,
              wrapContent: _wrapContent,
            ),

          // 话题 Header（centerPostIndex > 0 时放在 before-center 区域）
          if (hasFirstPost && centerPostIndex > 0)
            SliverToBoxAdapter(
              child: _wrapContent(
                context,
                TopicDetailHeader(
                  detail: detail,
                  headerKey: headerKey,
                  onVoteChanged: onVoteChanged,
                  onNotificationLevelChanged: onNotificationLevelChanged,
                ),
              ),
            ),

          // Before-center 帖子（文档顺序，Viewport 自动反转渲染）
          for (int i = 0; i < centerPostIndex; i++)
            _buildPostSliver(context, theme, posts[i], i),

          // 中心帖子（带 centerKey）
          _buildCenterSliver(context, theme, posts, hasFirstPost),

          // After-center 帖子
          for (int i = centerPostIndex + 1; i < posts.length; i++)
            _buildPostSliver(context, theme, posts[i], i),

          // 正在输入指示器（始终占位，通过 AnimatedSize 平滑过渡避免列表抖动）
          if (!hasMoreAfter)
            SliverToBoxAdapter(
              child: _wrapContent(
                context,
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: TypingAvatars(users: typingUsers),
                ),
              ),
            ),

          // 底部加载骨架屏
          if (hasMoreAfter && isLoadingMore)
            LoadingSkeletonSliver(
              itemCount: loadMoreSkeletonCount,
              wrapContent: _wrapContent,
            ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: 80 + MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }

  /// 构建中心帖子 Sliver
  Widget _buildCenterSliver(BuildContext context, ThemeData theme, List<Post> posts, bool hasFirstPost) {
    if (centerPostIndex == 0 && hasFirstPost) {
      // 话题 Header 和第一个帖子组合为 center
      return SliverMainAxisGroup(
        key: centerKey,
        slivers: [
          SliverToBoxAdapter(
            child: _wrapContent(
              context,
              TopicDetailHeader(
                detail: detail,
                headerKey: headerKey,
                onVoteChanged: onVoteChanged,
                onNotificationLevelChanged: onNotificationLevelChanged,
              ),
            ),
          ),
          _buildPostSliver(context, theme, posts[0], 0),
        ],
      );
    }
    return _buildPostSliver(
      context, theme, posts[centerPostIndex], centerPostIndex,
      key: centerKey,
    );
  }

  /// 构建单个帖子 Sliver
  ///
  /// 每个帖子独立一个 SliverToBoxAdapter，实现帖子级虚拟化。
  /// 长帖子的 HTML 分块由 PostItem 内的 ChunkedHtmlContent 处理（Column + SelectionArea），
  /// 保留跨块文本选择。
  Widget _buildPostSliver(BuildContext context, ThemeData theme, Post post, int postIndex, {Key? key}) {
    final showDivider = dividerPostIndex == postIndex;

    return SliverToBoxAdapter(
      key: key,
      child: _wrapContent(
        context,
        AutoScrollTag(
          key: ValueKey('post-${post.postNumber}'),
          controller: scrollController,
          index: postIndex,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showDivider)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  child: Text(
                    '上次看到这里',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              PostItem(
                post: post,
                topicId: detail.id,
                highlight: highlightPostNumber == post.postNumber,
                isTopicOwner: detail.createdBy?.username == post.username,
                topicHasAcceptedAnswer: detail.hasAcceptedAnswer,
                acceptedAnswerPostNumber: detail.acceptedAnswerPostNumber,
                onLike: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('点赞功能开发中...')),
                ),
                onReply: isLoggedIn ? () => onReply(post.postNumber == 1 ? null : post) : null,
                onEdit: isLoggedIn && post.canEdit ? () => onEdit(post) : null,
                onShareAsImage: onShareAsImage != null ? () => onShareAsImage!(post) : null,
                onRefreshPost: onRefreshPost,
                onJumpToPost: onJumpToPost,
                onSolutionChanged: onSolutionChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
