import 'dart:async' show Timer;
import 'package:common_ui/common_ui.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../utils/idle_task.dart';

import 'package:app_icons/app_icons.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../models/pending_post.dart';
import '../../../providers/message_bus_providers.dart';
import '../../../services/toast_service.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../../utils/responsive.dart';
import '../../../utils/scroll_busy_signal.dart';
import '../../../utils/time_utils.dart';
import '../controllers/topic_detail_controller.dart'
    show topicPostListLeadingItemCount;
import '../../../widgets/common/positioned_stream_list.dart';
import '../../../widgets/post/post_item/widgets/post_voting_answer_header.dart';

import 'package:m3e_ui/m3e_ui.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show
        BlockNode,
        HeadingAnchorRegistry,
        HeadingAnchorScope,
        HtmlChunk,
        ParagraphWarmup,
        ParagraphWarmupProbe;

import '../../../widgets/post/post_item/post_item.dart';
import '../../../widgets/post/post_item/render_parse_cache.dart';
import '../../../widgets/post/post_item/segmented_long_post.dart';
import '../../../widgets/post/small_action_item.dart' show PostTypes;
import '../../../widgets/post/quote_image_scope.dart';
import 'topic_detail_header.dart';
import 'shared_issue_button.dart';
import 'topic_more_topics.dart';
import 'topic_status_notices.dart';
import 'typing_indicator.dart';
import 'pending_posts_section.dart';
import 'private_message_participants.dart';

/// 话题帖子列表
/// 负责构建 CustomScrollView 及其 Slivers
///
/// 帖子分块、标题和推荐区共享一个正向虚拟列表。
/// 引擎负责动态高度锚定和精确索引定位，离开缓存范围的媒体照常回收。
class TopicPostList extends StatefulWidget {
  final TopicDetail detail;
  final AutoScrollController scrollController;
  final ListController listController;
  final int positionRevision;
  final GlobalKey headerKey;

  final int? selectedPostNumber;
  final int? highlightPostNumber;
  final bool isLoggedIn;
  final int? removingPrivateMessageParticipantId;
  final String? removingPrivateMessageGroupName;
  final ValueChanged<TopicUser>? onRemovePrivateMessageParticipant;
  final ValueChanged<TopicGroup>? onRemovePrivateMessageGroup;
  final VoidCallback? onInvitePrivateMessageParticipants;
  final bool hasMoreBefore;
  final bool hasMoreAfter;

  /// 分页加载/失败状态(provider 的 ValueNotifier)。指示器由列表内
  /// ValueListenableBuilder 就地切换,分页起止不触发整页 rebuild。
  final ValueListenable<bool> loadingPreviousListenable;
  final ValueListenable<bool> loadingMoreListenable;
  final ValueListenable<bool> loadMoreFailedListenable;
  final ValueListenable<bool> loadPreviousFailedListenable;
  final VoidCallback? onRetryLoadMore;
  final VoidCallback? onRetryLoadPrevious;
  final int initialPostIndex;
  final int? dividerPostIndex;
  final void Function(int postNumber) onFirstVisiblePostChanged;
  final void Function(Set<int> visiblePostNumbers)? onVisiblePostsChanged;
  final void Function(Map<int, int>)? onScrollIndexMappingChanged;
  final void Function(Map<int, int>)? onScrollIndexToPostNumberChanged;
  final void Function(Map<int, ({int firstScrollIndex, int lastScrollIndex})>)?
  onPostSegmentRangesChanged;
  final void Function(int postNumber) onJumpToPost;
  final void Function(Post? replyToPost, {String? initialContent}) onReply;
  final void Function(Post post) onEdit;
  final void Function(Post post)? onShareAsImage;
  final void Function(int postId) onRefreshPost;
  final void Function(int, bool) onVoteChanged;
  final void Function(int count, bool userCreated)? onSharedIssueChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final void Function(String selectedText, Post post)? onQuoteSelection;

  /// 图片引用回调（长按图片 → 引用）
  final void Function(String quote, Post post)? onQuoteImage;
  final bool Function(ScrollNotification) onScrollNotification;
  final VoidCallback? onLayoutChanged;
  final ValueChanged<double>? onPointerScroll;

  /// Gap 回调（拉黑用户帖子加载）
  final void Function(int postId)? onFillGapBefore;
  final void Function(int postId)? onFillGapAfter;

  /// 展开隐藏帖子回调
  final void Function(int postId)? onExpandHiddenPost;

  /// 是否使用弹框展示回复（过滤模式下）
  final bool useReplyDialog;

  /// 查看帖子详情回调
  final void Function(Post post)? onShowPostDetail;

  /// 待审核回复操作回调(撤回 / 撤回并重新编辑);任一为 null 则不显示待审块
  final void Function(PendingPost pending)? onWithdrawPendingPost;
  final void Function(PendingPost pending)? onWithdrawAndEditPendingPost;

  /// 高亮指定用户的 boost（从 boost 通知跳转时使用）
  final String? highlightBoostUsername;
  final bool hideHeaderTitle;

  /// 当前用户是否有指定权限(discourse-assign can_assign)——控制每条
  /// 帖子"更多"菜单里"指定帖子"这一项是否显示。
  final bool canAssignPost;

  /// 话题目录(TOC)的标题锚点注册表;非 null 时给 1 楼各段包
  /// HeadingAnchorScope,标题挂载即注册(跳转/高亮定位用)。
  final HeadingAnchorRegistry? headingAnchorRegistry;

  /// 问答话题排序(「N 个回答」头部的按票数/按活动 pill):
  /// null = 非问答话题不渲染头部
  final bool isActivitySort;
  final ValueChanged<bool>? onAnswerSortChanged;

  const TopicPostList({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.listController,
    required this.positionRevision,
    required this.headerKey,
    required this.selectedPostNumber,
    required this.highlightPostNumber,
    this.highlightBoostUsername,
    this.hideHeaderTitle = false,
    this.canAssignPost = false,
    required this.isLoggedIn,
    this.removingPrivateMessageParticipantId,
    this.removingPrivateMessageGroupName,
    this.onRemovePrivateMessageParticipant,
    this.onRemovePrivateMessageGroup,
    this.onInvitePrivateMessageParticipants,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.loadingPreviousListenable,
    required this.loadingMoreListenable,
    required this.loadMoreFailedListenable,
    required this.loadPreviousFailedListenable,
    this.onRetryLoadMore,
    this.onRetryLoadPrevious,
    required this.initialPostIndex,
    required this.dividerPostIndex,
    required this.onFirstVisiblePostChanged,
    this.onVisiblePostsChanged,
    this.onScrollIndexMappingChanged,
    this.onScrollIndexToPostNumberChanged,
    this.onPostSegmentRangesChanged,
    required this.onJumpToPost,
    required this.onReply,
    required this.onEdit,
    this.onShareAsImage,
    required this.onRefreshPost,
    required this.onVoteChanged,
    this.onSharedIssueChanged,
    this.onNotificationLevelChanged,
    this.onSolutionChanged,
    this.onQuoteSelection,
    this.onQuoteImage,
    required this.onScrollNotification,
    this.onLayoutChanged,
    this.onPointerScroll,
    this.onFillGapBefore,
    this.onFillGapAfter,
    this.onExpandHiddenPost,
    this.useReplyDialog = false,
    this.onShowPostDetail,
    this.onWithdrawPendingPost,
    this.onWithdrawAndEditPendingPost,
    this.isActivitySort = false,
    this.onAnswerSortChanged,
    this.headingAnchorRegistry,
  });

  @override
  State<TopicPostList> createState() => _TopicPostListState();
}

class _TopicPostListState extends State<TopicPostList> {
  void _onItemPositionsChanged() {
    if (!mounted) return;
    _updateFirstVisiblePost();
    // 精确跳转和高度修正发生在布局期，不发 ScrollController 通知。
    // 同步通知宿主检查分页边界、标题可见性和阅读进度。
    widget.onLayoutChanged?.call();
  }

  int? _lastReportedPostNumber;

  /// TYPING 诊断日志去重:上次记录的 typing 人数(见 build 内 Consumer)
  int? _lastLoggedTypingCount;
  List<_PostRenderSegment> _renderSegments = const [];
  Map<int, int> _postIndexToScrollIndex = const {};
  Map<int, int> _scrollIndexToPostNumber = const {};

  /// segments 记忆化依据：posts / gaps 均为不可变数据(riverpod 状态更新
  /// 总是换新实例)，身份不变即内容不变，build 时可跳过整个重建
  List<Post>? _segmentsSourcePosts;
  PostStreamGaps? _segmentsSourceGaps;

  /// postNumber → postIndex 反查表（避免 indexWhere 线性查找）
  Map<int, int> _postNumberToIndex = const {};

  final Map<int, _LongPostRenderCacheEntry> _longPostRenderCache = {};

  /// shortPost 段的 widget 实例缓存(key: post.id):构建输入未变化时
  /// 返回同一实例,框架在 Element.updateChild 处短路,整楼子树跳过
  /// rebuild。detail 的任何状态更新(message bus 单帖点赞、分页落地等)
  /// 都会从页面顶层整页 rebuild —— 实测一次 60ms,其中主要成本就是
  /// 未变化楼层的重复构建;有此缓存后只有真正变化的楼层重建。
  /// Post 与 detail 均为不可变数据(riverpod 更新总是换新实例),
  /// 引用相同即内容相同,签名比对安全。
  final Map<int, _ShortPostCacheEntry> _shortPostCache = {};

  /// 长帖正文 chunk 的 widget 实例缓存(key: (post.id, chunkIndex)),
  /// 语义同上;data 实例由 [_longPostDataFor] 的内容签名保证稳定。
  final Map<(int, int), _ChunkWidgetCacheEntry> _chunkWidgetCache = {};

  PrivateMessageParticipants _buildPrivateMessageParticipants(
    PrivateMessageParticipantsLocation location,
  ) {
    return PrivateMessageParticipants.fromDetail(
      location: location,
      detail: detail,
      removingParticipantId: widget.removingPrivateMessageParticipantId,
      removingGroupName: widget.removingPrivateMessageGroupName,
      onRemoveParticipant: widget.onRemovePrivateMessageParticipant,
      onRemoveGroup: widget.onRemovePrivateMessageGroup,
      onInvite: widget.onInvitePrivateMessageParticipants,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.listController.itemPositions.addListener(_onItemPositionsChanged);
    _listenToPreviousLoading();
    // 首帧渲染后触发一次可见性检测，确保进入页面时即上报阅读状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateFirstVisiblePost();
      }
    });
    // 滚动回跳探针:捕捉"滚动中内容被反向拉回"。单帧内 offset 反向
    // 跳变通常来自布局高度记账不一致触发的 scroll offset correction
    // (如重挂载的媒体尺寸与缓存中的高度不同)。
    // 事件经 FrameJankMonitor 汇入诊断时间轴(监控关闭时零输出),
    // listener 本体每帧只做几次数值比较,release 常驻注册无碍。
    widget.scrollController.addListener(_scrollJumpProbe);
  }

  late Listenable _previousLoadingChanges;

  void _listenToPreviousLoading() {
    _previousLoadingChanges = Listenable.merge([
      widget.loadingPreviousListenable,
      widget.loadPreviousFailedListenable,
    ]);
    _previousLoadingChanges.addListener(_onPreviousLoadingChanged);
  }

  void _onPreviousLoadingChanged() {
    final controller = widget.listController;
    if (!controller.isAttached || controller.numberOfItems == 0) return;
    // 空闲时页首行高度为 0，离开缓存后可能不再挂载。
    // 从列表外使高度缓存失效，下一轮加载和失败重试才能重新显示。
    controller.invalidateExtent(0);
  }

  @override
  void didUpdateWidget(covariant TopicPostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loadingPreviousListenable !=
            oldWidget.loadingPreviousListenable ||
        widget.loadPreviousFailedListenable !=
            oldWidget.loadPreviousFailedListenable) {
      _previousLoadingChanges.removeListener(_onPreviousLoadingChanged);
      _listenToPreviousLoading();
    }
  }

  double? _probeLastPixels;
  int _probeDirection = 0;

  void _scrollJumpProbe() {
    if (!FrameJankMonitor.isRunning) return;
    if (!widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    final pixels = position.pixels;
    final last = _probeLastPixels;
    _probeLastPixels = pixels;
    if (last == null) return;
    final delta = pixels - last;
    if (delta == 0) return;
    final direction = delta > 0 ? 1 : -1;
    // 与最近滚动方向相反且单次跳变 >8px:用户反向拖动一般达不到,
    // 惯性/动画中出现即为程序性修正
    if (_probeDirection != 0 &&
        direction != _probeDirection &&
        delta.abs() > 8) {
      // overscroll 回弹(位置在边界外)是 BouncingScrollPhysics 常态,
      // 方向必然反转,不是布局跳变 —— 过滤,只记内容区内的程序性修正
      // (生产样本:一轮 13 次 jump 里大半是边界回弹噪音)
      final minExtent = position.minScrollExtent;
      final maxExtent = position.maxScrollExtent;
      final inBounds =
          pixels >= minExtent &&
          pixels <= maxExtent &&
          last >= minExtent &&
          last <= maxExtent;
      if (inBounds) {
        FrameJankMonitor.logEvent(
          'SCROLL-PROBE',
          'backward jump ${delta.toStringAsFixed(1)}px '
              'at ${pixels.toStringAsFixed(1)} '
              '(min ${minExtent.toStringAsFixed(1)}, '
              'max ${maxExtent.toStringAsFixed(1)}) '
              '| 挂载: ${_mountedSegmentsSummary()} '
              '| 近帧构建: ${FrameJankMonitor.recentBuildNotes()}',
        );
      }
    }
    _probeDirection = direction;
  }

  /// 跳变现场:当前挂载的 segment 摘要。回跳的根因是"某类 item 重挂载
  /// 时高度与上次记账不同",每次跳变记录现场类型分布,几次样本对比即可
  /// 锁定是哪类内容(video/onebox/长帖 chunk...)高度不稳。
  String _mountedSegmentsSummary() {
    final parts = <String>[];
    for (final entry in scrollController.tagMap.entries) {
      final ctx = entry.value.context;
      if (!ctx.mounted) continue;
      final idx = entry.key;
      if (idx < 0 || idx >= _renderSegments.length) continue;
      final s = _renderSegments[idx];
      final chunk = s.chunkIndex != null ? ':${s.chunkIndex}' : '';
      parts.add('${s.type.name}#${s.post.postNumber}$chunk');
      if (parts.length >= 10) break;
    }
    return parts.isEmpty ? '(无)' : parts.join(' ');
  }

  @override
  void dispose() {
    _previousLoadingChanges.removeListener(_onPreviousLoadingChanged);
    widget.listController.itemPositions.removeListener(_onItemPositionsChanged);
    widget.scrollController.removeListener(_scrollJumpProbe);
    _parseWarmUpRetry?.cancel();
    super.dispose();
  }

  // 便捷 getter，简化 widget.xxx 访问
  TopicDetail get detail => widget.detail;
  AutoScrollController get scrollController => widget.scrollController;
  GlobalKey get headerKey => widget.headerKey;
  int? get selectedPostNumber => widget.selectedPostNumber;
  int? get highlightPostNumber => widget.highlightPostNumber;
  bool get isLoggedIn => widget.isLoggedIn;
  bool get hasMoreBefore => widget.hasMoreBefore;
  bool get hasMoreAfter => widget.hasMoreAfter;
  VoidCallback? get onRetryLoadMore => widget.onRetryLoadMore;
  VoidCallback? get onRetryLoadPrevious => widget.onRetryLoadPrevious;
  int get initialPostIndex => widget.initialPostIndex;
  int? get dividerPostIndex => widget.dividerPostIndex;
  void Function(int postNumber) get onJumpToPost => widget.onJumpToPost;
  void Function(Post? replyToPost, {String? initialContent}) get onReply =>
      widget.onReply;
  void Function(Post post) get onEdit => widget.onEdit;
  void Function(Post post)? get onShareAsImage => widget.onShareAsImage;
  void Function(int postId) get onRefreshPost => widget.onRefreshPost;
  void Function(int, bool) get onVoteChanged => widget.onVoteChanged;
  void Function(int count, bool userCreated)? get onSharedIssueChanged =>
      widget.onSharedIssueChanged;
  void Function(TopicNotificationLevel)? get onNotificationLevelChanged =>
      widget.onNotificationLevelChanged;
  void Function(int postId, bool accepted)? get onSolutionChanged =>
      widget.onSolutionChanged;
  void Function(String selectedText, Post post)? get onQuoteSelection =>
      widget.onQuoteSelection;
  void Function(String quote, Post post)? get onQuoteImage =>
      widget.onQuoteImage;
  bool Function(ScrollNotification) get onScrollNotification =>
      widget.onScrollNotification;
  void Function(Set<int> visiblePostNumbers)? get onVisiblePostsChanged =>
      widget.onVisiblePostsChanged;
  void Function(int postId)? get onFillGapBefore => widget.onFillGapBefore;
  void Function(int postId)? get onFillGapAfter => widget.onFillGapAfter;
  void Function(int postId)? get onExpandHiddenPost =>
      widget.onExpandHiddenPost;
  bool get useReplyDialog => widget.useReplyDialog;

  /// 检测当前可见帖子（Eyeline 机制）
  ///
  /// 参考 Discourse 官方实现（post-stream-viewport-tracker.js）的 eyeline 算法：
  /// Eyeline 是一条虚拟水平线，代表用户"正在看"的位置。
  /// - 大部分滚动过程中，eyeline 固定在视口顶部，当前帖子即顶部帖子
  /// - 接近底部的最后一个视口距离内，eyeline 逐渐从顶部移向底部
  /// - 滚到最底时，eyeline 在视口底部，确保能显示最后一个帖子
  /// 这使得进度指示器在整个滚动过程中平滑过渡，无需硬编码特殊情况。
  void _updateFirstVisiblePost() {
    final posts = detail.postStream.posts;
    if (posts.isEmpty) return;

    final tagMap = scrollController.tagMap;
    if (tagMap.isEmpty) return;

    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    // 弹簧过冲(BouncingScrollPhysics 出界回弹)期间冻结上报:出界时
    // remainingScroll 被压出正常区间,progress 被 clamp 到 0/1,eyeline
    // 钉死在视口顶/底;过冲还会把列表边缘帖(最后一帖等)拉进视口,
    // closest 兜底必命中它 —— 进度条瞬跳到 N/N(或视口顶帖),回弹才
    // 恢复;visiblePosts 误报更会经 screenTrack 把末帖标记已读,污染
    // 服务端 lastRead。回界后滚动通知会再次触发本方法,无需补偿。
    if (position.outOfRange) return;
    final viewportHeight = position.viewportDimension;

    // 视口可见区域的上下边界
    final topBoundary = kToolbarHeight + MediaQuery.of(context).padding.top;
    final bottomBoundary = viewportHeight;

    // === 计算 eyeline 位置 ===
    double eyeline;
    if (hasMoreAfter) {
      // 还有更多帖子未加载，eyeline 固定在顶部（标准行为）
      eyeline = topBoundary;
    } else {
      // 所有帖子已加载，根据滚动进度动态计算 eyeline
      final remainingScroll = position.maxScrollExtent - position.pixels;
      final totalScrollRange =
          position.maxScrollExtent - position.minScrollExtent;
      // eyeline 在最后一个视口距离内从顶部过渡到底部
      final scrollableArea = viewportHeight.clamp(0.0, totalScrollRange);
      final progress = scrollableArea > 0
          ? (1 - (remainingScroll / scrollableArea).clamp(0.0, 1.0))
          : 1.0;
      eyeline = topBoundary + progress * (bottomBoundary - topBoundary);
    }

    // === 找到 eyeline 所在的帖子并收集可见帖子 ===
    int? eyelinePostIndex;
    final visiblePostNumbers = <int>{};
    double closestDistance = double.infinity;
    int? closestPostIndex;

    for (final entry in tagMap.entries) {
      final postNumber = _scrollIndexToPostNumber[entry.key];
      if (postNumber == null) continue;

      final ctx = entry.value.context;
      if (!ctx.mounted) continue;

      // ctx.mounted 仅意味着 element 不为 null,但 inactive 状态下
      // (element 已从树中拆除,等待 unmount) findRenderObject 仍会抛
      // "Cannot get renderObject of inactive element"。
      // 唯一可靠的做法是 try-catch + 跳过,避免一条死 tag 中断整个循环
      // 让进度卡在最后一次成功的 post。
      final RenderBox? renderBox;
      try {
        renderBox = ctx.findRenderObject() as RenderBox?;
      } catch (_) {
        continue;
      }
      if (renderBox == null || !renderBox.hasSize || !renderBox.attached) {
        continue;
      }

      final topY = renderBox.localToGlobal(Offset.zero).dy;
      final bottomY = topY + renderBox.size.height;

      // 收集可见帖子（帖子与视口有交集）
      if (topY < viewportHeight && bottomY > topBoundary) {
        visiblePostNumbers.add(postNumber);
      }

      // 帖子包含 eyeline → 即为当前帖子
      if (topY <= eyeline && bottomY > eyeline) {
        eyelinePostIndex = _postNumberToIndex[postNumber];
      }

      // 记录距 eyeline 最近的帖子（兜底用）
      final distance = topY > eyeline
          ? topY - eyeline
          : (bottomY < eyeline ? eyeline - bottomY : 0.0);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestPostIndex = _postNumberToIndex[postNumber];
      }
    }

    // 没有帖子包含 eyeline 时（如处于帖子间隙或底部留白），取最近的帖子
    eyelinePostIndex ??= closestPostIndex;

    // 通知可见帖子变化（用于 screenTrack）
    if (visiblePostNumbers.isNotEmpty) {
      onVisiblePostsChanged?.call(visiblePostNumbers);
    }

    if (eyelinePostIndex != null) {
      final reportPostNumber = posts[eyelinePostIndex].postNumber;

      // 防止重复报告相同的帖子
      if (reportPostNumber != _lastReportedPostNumber) {
        _lastReportedPostNumber = reportPostNumber;
        widget.onFirstVisiblePostChanged(reportPostNumber);
      }
    }
  }

  /// 可见性由引擎布局后的 itemPositions 统一更新。
  bool _handleScrollNotification(ScrollNotification notification) {
    final result = onScrollNotification(notification);
    if (notification is ScrollEndNotification) {
      _scheduleChunkWarmUp();
    }

    return result;
  }

  /// 滚动停下后空闲预热,两级流水(单 idle task 只做一小步,不与滚动帧
  /// 抢主线程;新滚动开始 _warmUpGeneration 递增即全部停):
  ///
  /// 1. **chunk 预解析**(原有):把已进列表的长帖中尚未解析的 chunk
  ///    逐块解析(1-3ms/块),再滚到时 parse 命中 RenderParseCache;
  /// 2. **段落预 flatten + 预排版**(笔2 新增):对滚动方向前方的楼层,
  ///    把顶层段落 flatten 进 FlattenCache、纯文字段落排版进
  ///    ParagraphLayoutCache —— 首次滚到也全程查表(直绘零排版)。
  ///    缓存 key 经 ParagraphWarmupProbe 探针取自真实挂载(theme/
  ///    baseStyle/env/宽度全同源,不手工重建);探针未收敛(首屏尚无
  ///    直绘块挂载)则本轮只跑第 1 级。
  int _warmUpGeneration = 0;

  /// 段落预热游标:(postId, nodeIndex);楼层列表变化后从头再扫
  /// (已热的段落是缓存命中,重扫只付查表成本)。
  int? _warmPostCursor;
  int _warmNodeCursor = 0;

  void _scheduleChunkWarmUp() {
    final generation = ++_warmUpGeneration;
    void step() {
      if (!mounted || generation != _warmUpGeneration) return;
      // ---- 级 1:未解析 chunk ----
      LongPostParseData? pending;
      for (final entry in _longPostRenderCache.values) {
        final data = entry.newEngineData?.parseData;
        if (data != null && !data.fullyParsed) {
          pending = data;
          break;
        }
      }
      if (pending != null) {
        // scheduleIdleTask 是我们自己包的安全版:Flutter 3.44 的
        // SchedulerBinding.scheduleTask(idle) 撞上持续动画会让事件循环
        // 忙等活锁(Windows 上表现为窗口卡死),原生 scheduleTask 不能用。
        scheduleIdleTask(() {
          pending!.warmUpOneChunk();
          step();
        }, isCanceled: () => !mounted || generation != _warmUpGeneration);
        return;
      }
      // ---- 级 2:方向前方楼层的段落 flatten + 排版 ----
      _scheduleParagraphWarmUp(generation);
    }

    step();
  }

  /// 段落预热一步:取滚动方向前方(向下读 = 当前楼层之后)最近的
  /// 未热完楼层,预热其顶层段落;单步预算 4ms,步进由 idle task 驱动。
  void _scheduleParagraphWarmUp(int generation) {
    final snapshot = ParagraphWarmupProbe.snapshot();
    if (snapshot == null) return; // 探针未收敛,等下次滚动停止再试
    final posts = detail.postStream.posts;
    if (posts.isEmpty) return;

    // 从当前可见楼层向后扫(简化方向感知:向下阅读是绝对主流;向上
    // 回滚由 FlattenCache/LayoutCache 的 LRU 覆盖 —— 刚看过的都在)。
    final anchorNumber = _lastReportedPostNumber;
    var startIndex = anchorNumber == null
        ? 0
        : (_postNumberToIndex[anchorNumber] ?? 0);
    // 游标续跑:同一楼层没热完接着热,否则从锚点楼层往后找。
    // scheduleIdleTask 是我们自己包的安全版,原因见 _scheduleChunkWarmUp
    // 顶部注释(原生 SchedulerBinding.scheduleTask(idle) 撞持续动画会
    // 活锁)。
    scheduleIdleTask(() {
      // 找目标楼层:游标楼层仍有效则续,否则从 startIndex 起第一个
      // 已有解析产物的楼层(不为预热触发解析 —— 短帖解析很便宜但
      // 语义上归级 1/首建;这里只吃现成 AST)。
      List<BlockNode>? nodes;
      int? postId;
      if (_warmPostCursor != null) {
        final idx = posts.indexWhere((p) => p.id == _warmPostCursor);
        if (idx >= 0) {
          nodes = _warmNodesFor(posts[idx]);
          postId = _warmPostCursor;
        }
      }
      if (nodes == null) {
        _warmNodeCursor = 0;
        for (var i = startIndex; i < posts.length; i++) {
          final candidate = _warmNodesFor(posts[i]);
          if (candidate != null && candidate.isNotEmpty) {
            // 已全热完的楼层 warmParagraphs 一圈查表(<0.1ms)后返回 -1,
            // 游标自然推进,不重复付费。
            nodes = candidate;
            postId = posts[i].id;
            break;
          }
        }
      }
      if (nodes == null || postId == null) return; // 前方无可热楼层,收工

      final next = ParagraphWarmup.warmParagraphs(
        nodes: nodes,
        ctx: snapshot,
        context: context,
        // 预热产物按 (inlines 身份, style, theme) 进全局缓存,handler 用
        // 共享 static(emoji/mention/localDate/math/download)+ 无 post
        // 语境的兜底即可 —— 挂载时若 handler 语义不同也不影响:内容同
        // 身份 → 命中的是 span/排版,recognizer 行为经 mount 桥现取活
        // context,linkHandler 闭包冻结的 post.id 仅用于点击追踪,预热
        // 段落全部来自「该 post 自己的 AST」,forPost 语义一致。
        totalImagesInPost: 0,
        startIndex: _warmNodeCursor,
        budgetMicros: 4000,
      );
      if (next == -1) {
        // 本楼层热完,游标移到下一楼层(下一步找)。
        final idx = posts.indexWhere((p) => p.id == postId);
        _warmPostCursor = (idx >= 0 && idx + 1 < posts.length)
            ? posts[idx + 1].id
            : null;
        _warmNodeCursor = 0;
        if (_warmPostCursor == null) return; // 到底了
      } else {
        _warmPostCursor = postId;
        _warmNodeCursor = next;
      }
      _scheduleParagraphWarmUp(generation); // 下一 idle 步
    }, isCanceled: () => !mounted || generation != _warmUpGeneration);
  }

  /// 楼层的现成 AST(只取已解析的,不触发解析):
  /// - 短帖:RenderParseCache.shortPost(命中即回;未解析过的短帖
  ///   解析本身 1-3ms,顺带做了也无妨 —— shortPost 内部会解析并缓存);
  /// - 长帖:各 chunk 均已由级 1 热过,拼接全部 chunk 节点。
  List<BlockNode>? _warmNodesFor(Post post) {
    final longEntry = _longPostRenderCache[post.id];
    final parseData = longEntry?.newEngineData?.parseData;
    if (parseData != null) {
      if (!parseData.fullyParsed) return null; // 级 1 尚未完成,先跳过
      final all = <BlockNode>[];
      for (var i = 0; i < parseData.chunks.length; i++) {
        all.addAll(parseData.parsedChunkAt(i));
      }
      return all;
    }
    return RenderParseCache.shortPost(post).nodes;
  }

  String _segmentKey(_PostRenderSegment segment) {
    switch (segment.type) {
      case _PostRenderSegmentType.shortPost:
      case _PostRenderSegmentType.longHeader:
        return 'post-${segment.post.id}';
      case _PostRenderSegmentType.longChunk:
        return 'long-chunk-${segment.post.id}-${segment.chunkIndex}';
      case _PostRenderSegmentType.longFooter:
        return 'long-footer-${segment.post.id}';
      case _PostRenderSegmentType.gapBefore:
        return 'gap-before-${segment.post.id}';
      case _PostRenderSegmentType.gapAfter:
        return 'gap-after-${segment.post.id}';
    }
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapContent(BuildContext context, Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: child,
      ),
    );
  }

  void _buildRenderSegments(List<Post> posts) {
    // posts 与 gaps 身份都没变 → segments/映射表必然一致，直接复用。
    // 高亮/选中/typing 等高频 rebuild 不再重付 O(N) 的分段与建表成本
    final gaps = detail.postStream.gaps;
    if (identical(_segmentsSourcePosts, posts) &&
        identical(_segmentsSourceGaps, gaps)) {
      return;
    }
    final oldPosts = _segmentsSourcePosts;
    _segmentsSourcePosts = posts;
    _segmentsSourceGaps = gaps;
    // 计时归因:分页落地帧的「build 33ms 无构建记录」嫌疑之一(全量
    // O(N) 分段与建表)。>4ms 才上报,常态零输出;下份日志定其清白/有罪
    final segmentsStopwatch = Stopwatch()..start();

    final segments = <_PostRenderSegment>[];
    final postIndexToScrollIndex = <int, int>{};
    final scrollIndexToPostNumber = <int, int>{};
    final postNumberToIndex = <int, int>{};
    final postSegmentRanges =
        <int, ({int firstScrollIndex, int lastScrollIndex})>{};
    final activePostIds = <int>{};

    for (int postIndex = 0; postIndex < posts.length; postIndex++) {
      final post = posts[postIndex];
      activePostIds.add(post.id);
      final firstScrollIndex = segments.length;

      // 检查此帖子前面是否有 gap
      if (gaps != null && gaps.before.containsKey(post.id)) {
        final gapIds = gaps.before[post.id]!;
        if (gapIds.isNotEmpty) {
          scrollIndexToPostNumber[segments.length] = post.postNumber;
          segments.add(
            _PostRenderSegment.gapBefore(
              scrollIndex: segments.length,
              postIndex: postIndex,
              post: post,
              gapCount: gapIds.length,
            ),
          );
        }
      }

      // 长帖分段:新引擎用 NewEngineLongPostData(切预处理后 cooked,每 chunk 一个
      // FluxdoRender,sliver 虚拟化 → 不卡 + 滚动锚定原生)。
      final NewEngineLongPostData? newEngineData;
      final List<HtmlChunk> longChunks;
      final longPostCache = _longPostDataFor(post);
      newEngineData = longPostCache.newEngineData;
      longChunks = longPostCache.chunks;
      // discourse-assign 等插件的指定/取消指定系统帖,cooked 里塞几十个
      // emoji <img> 就很容易超过长帖分段阈值——这条 chunk 化直出路径是
      // topic_post_list.dart 自己直接调 LongPostHeaderSegment/Footer,完全
      // 绕过 PostItem.build() 里"是不是系统操作帖"的判断,系统帖一旦被
      // 判成"长帖"就会被当成能点赞/回复的普通帖子整个渲染出来。系统帖
      // 永远走 shortPost(内部再分流到 SmallActionItem),不参与长帖分段。
      final bool isSystemActionPost =
          post.postType == PostTypes.smallAction ||
          (post.actionCode?.isNotEmpty ?? false);
      final useLongSegments = !isSystemActionPost && longChunks.isNotEmpty;

      postIndexToScrollIndex[postIndex] = segments.length;
      postNumberToIndex[post.postNumber] = postIndex;

      if (!useLongSegments) {
        scrollIndexToPostNumber[segments.length] = post.postNumber;
        segments.add(
          _PostRenderSegment.shortPost(
            scrollIndex: segments.length,
            postIndex: postIndex,
            post: post,
          ),
        );
      } else {
        scrollIndexToPostNumber[segments.length] = post.postNumber;
        segments.add(
          _PostRenderSegment.header(
            scrollIndex: segments.length,
            postIndex: postIndex,
            post: post,
          ),
        );

        for (var ci = 0; ci < longChunks.length; ci++) {
          scrollIndexToPostNumber[segments.length] = post.postNumber;
          segments.add(
            _PostRenderSegment.chunk(
              scrollIndex: segments.length,
              postIndex: postIndex,
              post: post,
              chunkIndex: ci,
              chunkData: longChunks[ci],
              newEngineData: newEngineData,
            ),
          );
        }

        scrollIndexToPostNumber[segments.length] = post.postNumber;
        segments.add(
          _PostRenderSegment.footer(
            scrollIndex: segments.length,
            postIndex: postIndex,
            post: post,
          ),
        );
      }

      // 检查此帖子后面是否有 gap
      if (gaps != null && gaps.after.containsKey(post.id)) {
        final gapIds = gaps.after[post.id]!;
        if (gapIds.isNotEmpty) {
          scrollIndexToPostNumber[segments.length] = post.postNumber;
          segments.add(
            _PostRenderSegment.gapAfter(
              scrollIndex: segments.length,
              postIndex: postIndex,
              post: post,
              gapCount: gapIds.length,
            ),
          );
        }
      }

      postSegmentRanges[post.postNumber] = (
        firstScrollIndex: firstScrollIndex,
        lastScrollIndex: segments.length - 1,
      );
    }

    _longPostRenderCache.removeWhere(
      (postId, _) => !activePostIds.contains(postId),
    );
    // widget 实例缓存同步淘汰:离开 posts 的帖子(整流刷新/过滤模式)
    // 不再持有 widget 配置树;翻页只增不减,不受影响
    _shortPostCache.removeWhere((postId, _) => !activePostIds.contains(postId));
    _chunkWidgetCache.removeWhere((key, _) => !activePostIds.contains(key.$1));
    _renderSegments = segments;
    _postIndexToScrollIndex = postIndexToScrollIndex;
    _scrollIndexToPostNumber = scrollIndexToPostNumber;
    _postNumberToIndex = postNumberToIndex;
    segmentsStopwatch.stop();
    if (segmentsStopwatch.elapsedMilliseconds >= 4) {
      FrameJankMonitor.logEvent(
        'SEGMENTS',
        '重算 ${posts.length}帖→${segments.length}段 '
            '${segmentsStopwatch.elapsedMilliseconds}ms',
      );
    }
    widget.onScrollIndexMappingChanged?.call(postIndexToScrollIndex);
    widget.onScrollIndexToPostNumberChanged?.call(scrollIndexToPostNumber);
    widget.onPostSegmentRangesChanged?.call(postSegmentRanges);
    if (oldPosts != null && posts.length > oldPosts.length) {
      final previousIds = oldPosts.map((post) => post.id).toSet();
      _schedulePostParseWarmUp(
        posts.where((post) => !previousIds.contains(post.id)).toList(),
      );
    }
  }

  /// 新落地帖子的解析预热:idle 时间逐帖跑 [RenderParseCache.shortPost]
  /// (preprocess + DOM parse,单帖 1~5ms)。长帖跳过(chunk 懒解析 + 滚动停止后的
  /// [_scheduleChunkWarmUp] 已覆盖)。新一轮落地推进 generation,旧队列
  /// 自动作废;LRU 命中即免费,与物化竞争不会重复付费。
  ///
  /// 滚动让路:Priority.idle 只保证"排在帧任务后",帧间隙仍会执行 ——
  /// 单帖解析是原子长任务(debug 30~44ms),快滚中挤占事件循环就是
  /// 诊断时间轴上 STALL/HandleMessage 型 ov 掉帧的税源之一。滚动中
  /// (含惯性)暂停,静默后继续;正在滚动时进屏的未预热帖由物化帧
  /// 现场解析兜底(与预热是同一份工作,只是没抢到提前量)。
  int _parseWarmUpGeneration = 0;
  Timer? _parseWarmUpRetry;

  void _schedulePostParseWarmUp(List<Post> posts) {
    if (posts.isEmpty) return;
    final generation = ++_parseWarmUpGeneration;
    var index = 0;
    void step() {
      scheduleIdleTask(() {
        if (!mounted || generation != _parseWarmUpGeneration) return;
        if (ScrollBusySignal.isBusy) {
          _parseWarmUpRetry?.cancel();
          _parseWarmUpRetry = Timer(const Duration(milliseconds: 400), () {
            if (mounted && generation == _parseWarmUpGeneration) step();
          });
          return;
        }
        while (index < posts.length) {
          final post = posts[index++];
          // segments 构建已对每帖做过长短判定并落缓存,据此跳过长帖
          final isLong =
              _longPostRenderCache[post.id]?.chunks.isNotEmpty ?? false;
          if (isLong) continue;
          RenderParseCache.shortPost(post);
          break;
        }
        if (index < posts.length) step();
      });
    }

    step();
  }

  _LongPostRenderCacheEntry _longPostDataFor(Post post) {
    final signature = _longPostRenderSignature(post);
    final cached = _longPostRenderCache[post.id];
    if (cached != null && identical(cached.post, post)) {
      return cached;
    }
    // post 实例变了但渲染相关内容(cooked/mentions/links,即 signature
    // 覆盖的字段)没变 —— 典型场景:message bus 单帖更新(点赞数等)
    // copyWith 出新实例。复用解析产物,只刷新 post 引用;否则每次
    // 点赞推送都会重新预处理 + 切 chunk + 丢掉全部已解析 chunk,
    // 已挂载的 chunk 被迫同步重新解析,一次几十 ms。
    if (cached != null && cached.signature == signature) {
      final refreshed = _LongPostRenderCacheEntry(
        post: post,
        signature: signature,
        newEngineData: cached.newEngineData,
      );
      _longPostRenderCache[post.id] = refreshed;
      return refreshed;
    }

    final entry = _LongPostRenderCacheEntry(
      post: post,
      signature: signature,
      newEngineData: NewEngineLongPostData.tryBuild(
        post,
        topicId: detail.id,
        onQuoteImage: onQuoteImage,
      ),
    );
    _longPostRenderCache[post.id] = entry;
    return entry;
  }

  int _longPostRenderSignature(Post post) {
    final mentionedUsers = post.mentionedUsers;
    final linkCounts = post.linkCounts;
    return Object.hash(
      post.cooked.length,
      post.cooked.hashCode,
      mentionedUsers == null
          ? 0
          : Object.hashAll(
              mentionedUsers.map(
                (u) => Object.hash(
                  u.id,
                  u.username,
                  u.statusEmoji,
                  u.statusDescription,
                ),
              ),
            ),
      linkCounts == null
          ? 0
          : Object.hashAll(
              linkCounts.map(
                (l) => Object.hash(
                  l.url,
                  l.clicks,
                  l.title,
                  l.internal,
                  l.reflection,
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
    final previousSegments = _renderSegments;
    _buildRenderSegments(posts);
    final initialSegment = _postIndexToScrollIndex[initialPostIndex] ?? 0;
    final itemKeys = <String>[
      'load-previous',
      'topic-header',
      for (final segment in _renderSegments) _segmentKey(segment),
      'pending-posts',
      'typing',
      'load-more',
      'topic-status-notices',
      'suggested-topics',
      'pm-participants',
      'bottom-padding',
    ];

    return QuoteImageScope(
      handler: widget.onQuoteImage,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              widget.onPointerScroll?.call(event.scrollDelta.dy);
            }
          },
          child: PositionedStreamList(
            scrollController: scrollController,
            listController: widget.listController,
            positionKey: (
              detail.id,
              widget.positionRevision,
              _renderSegments.isEmpty,
            ),
            itemKeys: itemKeys,
            firstAnchorIndex: hasMoreBefore ? topicPostListLeadingItemCount : 0,
            fallbackAnchorKeys: {
              for (final segment in previousSegments)
                _segmentKey(segment): 'post-${segment.post.id}',
            },
            initialIndex: initialPostIndex == 0 && hasFirstPost
                ? 0
                : initialSegment + topicPostListLeadingItemCount,
            cacheExtent: Responsive.isMobile(context) ? 300 : 500,
            itemBuilder: (context, index) {
              if (index == 0) {
                return hasMoreBefore
                    ? _buildLoadingRow(context, previous: true)
                    : const SizedBox.shrink();
              }
              if (index == 1) {
                return hasFirstPost
                    ? _wrapContent(
                        context,
                        TopicDetailHeader(
                          detail: detail,
                          headerKey: headerKey,
                          showTitle: !widget.hideHeaderTitle,
                          onVoteChanged: onVoteChanged,
                          onNotificationLevelChanged:
                              onNotificationLevelChanged,
                          onJumpToPost: onJumpToPost,
                        ),
                      )
                    : const SizedBox.shrink();
              }
              final segmentIndex = index - topicPostListLeadingItemCount;
              if (segmentIndex < _renderSegments.length) {
                return _buildSegmentItem(
                  context,
                  _renderSegments[segmentIndex],
                );
              }
              return _buildTrailingRow(
                context,
                segmentIndex - _renderSegments.length,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingRow(BuildContext context, {required bool previous}) {
    final loading = previous
        ? widget.loadingPreviousListenable
        : widget.loadingMoreListenable;
    final failed = previous
        ? widget.loadPreviousFailedListenable
        : widget.loadMoreFailedListenable;
    return ListenableBuilder(
      listenable: Listenable.merge([loading, failed]),
      builder: (context, _) {
        if (failed.value) {
          return _LoadFailedRetry(
            onRetry: previous ? onRetryLoadPrevious : onRetryLoadMore,
          );
        }
        return loading.value
            ? _wrapContent(context, const _LoadMoreIndicator())
            : const SizedBox.shrink();
      },
    );
  }

  Widget _buildTrailingRow(BuildContext context, int index) {
    if (index == 6) {
      return SizedBox(height: 80 + MediaQuery.paddingOf(context).bottom);
    }
    if (hasMoreAfter) {
      return index == 2
          ? _buildLoadingRow(context, previous: false)
          : const SizedBox.shrink();
    }
    switch (index) {
      case 0:
        if (detail.pendingPosts.isEmpty ||
            widget.onWithdrawPendingPost == null ||
            widget.onWithdrawAndEditPendingPost == null) {
          return const SizedBox.shrink();
        }
        return _wrapContent(
          context,
          PendingPostsSection(
            pendingPosts: detail.pendingPosts,
            onWithdraw: widget.onWithdrawPendingPost!,
            onWithdrawAndEdit: widget.onWithdrawAndEditPendingPost!,
          ),
        );
      case 1:
        return _wrapContent(
          context,
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: Consumer(
              builder: (context, ref, _) {
                final users = ref.watch(
                  topicChannelProvider(detail.id)
                      .select((state) => state.typingUsers),
                );
                if (users.length != _lastLoggedTypingCount) {
                  _lastLoggedTypingCount = users.length;
                  FrameJankMonitor.logEvent('TYPING', '${users.length} users');
                }
                return TypingAvatars(users: users);
              },
            ),
          ),
        );
      case 3:
        return _wrapContent(context, TopicStatusNotices(detail: detail));
      case 4:
        return _wrapContent(context, MoreTopicsSection(detail: detail));
      case 5:
        return PrivateMessageParticipants.shouldShowAtBottom(detail)
            ? _wrapContent(
                context,
                _buildPrivateMessageParticipants(
                  PrivateMessageParticipantsLocation.bottom,
                ),
              )
            : const SizedBox.shrink();
      default:
        return const SizedBox.shrink();
    }
  }

  /// 判断是否需要显示日期分割线
  bool _shouldShowDateSeparator(int postIndex) {
    final posts = detail.postStream.posts;
    if (postIndex <= 0) return false;

    final currentDate = posts[postIndex].createdAt;
    final previousDate = posts[postIndex - 1].createdAt;

    final currentDay = DateTime(
      currentDate.year,
      currentDate.month,
      currentDate.day,
    );
    final previousDay = DateTime(
      previousDate.year,
      previousDate.month,
      previousDate.day,
    );

    return currentDay != previousDay;
  }

  Widget _buildSegmentItem(BuildContext context, _PostRenderSegment segment) {
    final post = segment.post;
    final postIndex = segment.postIndex;
    final showDivider = dividerPostIndex == postIndex;
    final showTopSeparator = _shouldShowDateSeparator(postIndex);
    final dateSeparatorLabel = showTopSeparator
        ? TimeUtils.formatSmartDate(post.createdAt)
        : null;
    final posts_ = detail.postStream.posts;
    final nextPostIndex = postIndex + 1;
    final showBottomSeparator =
        nextPostIndex < posts_.length &&
        _shouldShowDateSeparator(nextPostIndex);
    final bottomDateSeparatorLabel = showBottomSeparator
        ? TimeUtils.formatSmartDate(posts_[nextPostIndex].createdAt)
        : null;
    final isSelectedPost = selectedPostNumber == post.postNumber;
    final isTargetPost = highlightPostNumber == post.postNumber;
    final boostUsername = isTargetPost ? widget.highlightBoostUsername : null;
    // 能匹配到具体 boost 时不高亮帖子，匹配不到时回退到高亮帖子
    final canLocateBoost =
        boostUsername != null &&
        (post.boosts ?? []).any((b) => b.user.username == boostUsername);
    final highlight = isTargetPost && !canLocateBoost;
    final replyTarget = post.postNumber == 1 ? null : post;
    // 头像长按菜单「@用户」：新回复（不针对该楼）+ 预填 @username
    final void Function(String username)? onMentionUser = isLoggedIn
        ? (u) => onReply(null, initialContent: '@$u ')
        : null;
    // OP 帖底部的 "俺也一样" 按钮; 非 OP 或服务端没启用时为 null
    final Widget? opSlot = (post.postNumber == 1 && detail.sharedIssueVisible)
        ? SharedIssueButton(topic: detail, onChanged: onSharedIssueChanged)
        : null;
    // 问答话题:「N 个回答」头部渲染在第一个答案上方(问题帖紧邻其后
    // 的那一帖;仅问题帖已加载时才有可见的问题/答案分界)。挂在该帖
    // 首个段(shortPost 或长帖 header)顶部。
    final bool showAnswerHeader =
        detail.isPostVoting &&
        post.postNumber != 1 &&
        postIndex > 0 &&
        posts_[postIndex - 1].postNumber == 1 &&
        (segment.type == _PostRenderSegmentType.shortPost ||
            segment.type == _PostRenderSegmentType.longHeader);
    final Widget child;

    switch (segment.type) {
      case _PostRenderSegmentType.shortPost:
        Widget buildShortPost() => PostItem(
          post: post,
          topicId: detail.id,
          categoryId: detail.categoryId,
          selected: isSelectedPost,
          highlight: highlight,
          highlightBoostUsername: boostUsername,
          isTopicOwner: detail.createdBy?.username == post.username,
          topicHasAcceptedAnswer: detail.hasAcceptedAnswer,
          acceptedAnswers: detail.acceptedAnswers,
          dateSeparatorLabel: dateSeparatorLabel,
          bottomDateSeparatorLabel: bottomDateSeparatorLabel,
          onLike: () => ToastService.showInfo(S.current.ai_likeInDev),
          onReply: isLoggedIn
              ? ({initialContent}) =>
                    onReply(replyTarget, initialContent: initialContent)
              : null,
          onMentionUser: onMentionUser,
          onEdit: isLoggedIn && post.canEdit ? () => onEdit(post) : null,
          onShareAsImage: onShareAsImage != null
              ? () => onShareAsImage!(post)
              : null,
          onRefreshPost: onRefreshPost,
          onJumpToPost: onJumpToPost,
          onSolutionChanged: onSolutionChanged,
          onQuoteSelection: onQuoteSelection,
          onQuoteImage: onQuoteImage,
          onExpandHiddenPost: onExpandHiddenPost,
          useReplyDialog: useReplyDialog,
          assignmentInfo: detail.indirectlyAssignedTo[post.id],
          canAssignPost: widget.canAssignPost,
          topicTitle: detail.title,
          isPrivateMessageTopic: detail.isPrivateMessage,
          isPmWithNonHumanUser: detail.pmWithNonHumanUser,
          onShowPostDetail: widget.onShowPostDetail != null
              ? () => widget.onShowPostDetail!(post)
              : null,
          opTopSlot: opSlot,
          isPostVotingTopic: detail.isPostVoting,
          topicClosed: detail.closed || detail.archived,
        );

        // OP 楼的 opSlot 依赖整个 detail 对象,签名无法稳定,不缓存
        if (post.postNumber == 1) {
          child = buildShortPost();
          break;
        }

        // 实例缓存:输入未变时复用同一 widget 实例,让整页 rebuild 时
        // 未变化的楼层在框架层短路(闭包回调经 State 转发,行为始终
        // 跟随最新 widget,复用实例不会捕获旧数据)
        final signature = (
          post: post,
          selected: isSelectedPost,
          highlight: highlight,
          boostUsername: boostUsername,
          dateLabel: dateSeparatorLabel,
          bottomDateLabel: bottomDateSeparatorLabel,
          isTopicOwner: detail.createdBy?.username == post.username,
          hasAcceptedAnswer: detail.hasAcceptedAnswer,
          acceptedAnswers: detail.acceptedAnswers,
          isLoggedIn: isLoggedIn,
          useReplyDialog: useReplyDialog,
          topicTitle: detail.title,
          isPm: detail.isPrivateMessage,
          pmNonHuman: detail.pmWithNonHumanUser,
          canShareAsImage: onShareAsImage != null,
          canShowDetail: widget.onShowPostDetail != null,
          isPostVoting: detail.isPostVoting,
          topicClosed: detail.closed || detail.archived,
        );
        final cached = _shortPostCache[post.id];
        if (cached != null && cached.signature == signature) {
          child = cached.widget;
        } else {
          child = buildShortPost();
          _shortPostCache[post.id] = _ShortPostCacheEntry(
            signature: signature,
            widget: child,
          );
        }
        break;
      case _PostRenderSegmentType.longHeader:
        child = LongPostHeaderSegment(
          post: post,
          topicId: detail.id,
          selected: isSelectedPost,
          highlight: highlight,
          isTopicOwner: detail.createdBy?.username == post.username,
          dateSeparatorLabel: dateSeparatorLabel,
          showDivider: showDivider,
          onJumpToPost: onJumpToPost,
          onMentionUser: onMentionUser,
        );
        break;
      case _PostRenderSegmentType.longChunk:
        final data = segment.newEngineData!;
        final ci = segment.chunkIndex!;
        // 正文 chunk 的实例缓存:data(解析产物 + callbacks)实例稳定
        // (见 _longPostDataFor 的签名复用)且选中/高亮态不变时,复用
        // widget 实例让框架整棵短路。单帖更新(点赞等)触发的整页
        // rebuild 里,正文富文本的重建是最大头,这里短路后更新只剩
        // header/footer 的轻量重建。
        // 首 chunk 额外携带弹幕层(读 post.boosts/boostUsername),必须
        // 连 post 实例一起比对 —— 否则新 boost 到达后弹幕拿的还是旧数据。
        final chunkKey = (post.id, ci);
        final cachedChunk = _chunkWidgetCache[chunkKey];
        if (cachedChunk != null &&
            identical(cachedChunk.data, data) &&
            cachedChunk.selected == isSelectedPost &&
            cachedChunk.highlight == highlight &&
            (ci != 0 ||
                (identical(cachedChunk.post, post) &&
                    cachedChunk.boostUsername == boostUsername))) {
          child = cachedChunk.widget;
          break;
        }
        child = NewEngineChunkSegment(
          post: post,
          topicId: detail.id,
          selected: isSelectedPost,
          highlight: highlight,
          chunk: segment.chunkData!,
          chunkIndex: ci,
          // 懒解析:首次进入 cacheExtent 时才 parse 该 chunk(带前缀补齐),
          // 避免进话题/分页落地帧一次性解析长帖所有 chunk
          imageIndexOffset: data.imageOffsetAt(ci),
          parsedNodes: data.parsedChunkAt(ci),
          footnotesHtml: data.footnotesHtml,
          callbacks: data.callbacks,
          onQuoteSelection: onQuoteSelection,
          highlightBoostUsername: ci == 0 ? boostUsername : null,
          topicTitle: detail.title,
        );
        _chunkWidgetCache[chunkKey] = _ChunkWidgetCacheEntry(
          data: data,
          post: post,
          selected: isSelectedPost,
          highlight: highlight,
          boostUsername: boostUsername,
          widget: child,
        );
        break;
      case _PostRenderSegmentType.longFooter:
        child = LongPostFooterSegment(
          post: post,
          topicId: detail.id,
          categoryId: detail.categoryId,
          selected: isSelectedPost,
          highlight: highlight,
          highlightBoostUsername: boostUsername,
          topicHasAcceptedAnswer: detail.hasAcceptedAnswer,
          acceptedAnswers: detail.acceptedAnswers,
          bottomDateSeparatorLabel: bottomDateSeparatorLabel,
          onReply: isLoggedIn
              ? ({initialContent}) =>
                    onReply(replyTarget, initialContent: initialContent)
              : null,
          onEdit: isLoggedIn && post.canEdit ? () => onEdit(post) : null,
          onShareAsImage: onShareAsImage != null
              ? () => onShareAsImage!(post)
              : null,
          onRefreshPost: onRefreshPost,
          onJumpToPost: onJumpToPost,
          onSolutionChanged: onSolutionChanged,
          useReplyDialog: useReplyDialog,
          topicTitle: detail.title,
          isPrivateMessageTopic: detail.isPrivateMessage,
          isPmWithNonHumanUser: detail.pmWithNonHumanUser,
          onShowPostDetail: widget.onShowPostDetail != null
              ? () => widget.onShowPostDetail!(post)
              : null,
          opTopSlot: opSlot,
          isPostVotingTopic: detail.isPostVoting,
          topicClosed: detail.closed || detail.archived,
        );
        break;
      case _PostRenderSegmentType.gapBefore:
        child = _GapIndicator(
          count: segment.gapCount,
          onTap: onFillGapBefore != null
              ? () => onFillGapBefore!(post.id)
              : null,
        );
        break;
      case _PostRenderSegmentType.gapAfter:
        child = _GapIndicator(
          count: segment.gapCount,
          onTap: onFillGapAfter != null ? () => onFillGapAfter!(post.id) : null,
        );
        break;
    }

    final childWithParticipants =
        PrivateMessageParticipants.shouldShow(detail) &&
            post.postNumber == 1 &&
            (segment.type == _PostRenderSegmentType.shortPost ||
                segment.type == _PostRenderSegmentType.longFooter)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              child,
              _buildPrivateMessageParticipants(
                PrivateMessageParticipantsLocation.firstPost,
              ),
            ],
          )
        : child;

    // TOC 锚点作用域只挂 1 楼:节点 id 跨帖重复,其他楼的标题不能进
    // 注册表(见 HeadingAnchorRegistrar/headingAnchorKey)。
    final anchorRegistry = widget.headingAnchorRegistry;
    final scopedChild = anchorRegistry != null && post.postNumber == 1
        ? HeadingAnchorScope(
            registry: anchorRegistry,
            child: childWithParticipants,
          )
        : childWithParticipants;

    final wrapped = _wrapContent(
      context,
      AutoScrollTag(
        key: ValueKey(_segmentKey(segment)),
        controller: scrollController,
        index: segment.scrollIndex,
        // builder 直通:绕开 AutoScrollTag 默认的 buildHighlightTransition
        // 常驻 DecoratedBoxTransition 包装(项目不用包的 highlight 功能,
        // 楼层高亮是 PostItem 自己的 highlight 参数),每帖少一层
        // transition + tween 求值
        builder: (context, animation) => showAnswerHeader
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PostVotingAnswerHeader(
                    // 答案数 = 总帖数 - 1(减问题帖,官方同口径)
                    answerCount: (detail.postsCount - 1).clamp(0, 999999),
                    isActivityMode: widget.isActivitySort,
                    onSortChanged: (byActivity) =>
                        widget.onAnswerSortChanged?.call(byActivity),
                  ),
                  scopedChild,
                ],
              )
            : scopedChild,
      ),
    );

    return wrapped;
  }
}

enum _PostRenderSegmentType {
  shortPost,
  longHeader,
  longChunk,
  longFooter,
  gapBefore,
  gapAfter,
}

/// shortPost 段的实例缓存条目:signature 是构建输入的具名 record,
/// == 比较逐字段进行(Post / List 等按引用,不可变数据引用同即内容同)
class _ShortPostCacheEntry {
  final Object signature;
  final Widget widget;

  const _ShortPostCacheEntry({required this.signature, required this.widget});
}

/// 长帖正文 chunk 段的实例缓存条目
class _ChunkWidgetCacheEntry {
  final NewEngineLongPostData data;

  /// 首 chunk 弹幕层读 post.boosts,post 实例参与缓存签名
  final Post post;
  final bool selected;
  final bool highlight;
  final String? boostUsername;
  final Widget widget;

  const _ChunkWidgetCacheEntry({
    required this.data,
    required this.post,
    required this.selected,
    required this.highlight,
    required this.boostUsername,
    required this.widget,
  });
}

class _LongPostRenderCacheEntry {
  final Post post;
  final int signature;
  final NewEngineLongPostData? newEngineData;
  const _LongPostRenderCacheEntry({
    required this.post,
    required this.signature,
    this.newEngineData,
  });

  List<HtmlChunk> get chunks => newEngineData?.chunks ?? const <HtmlChunk>[];
}

class _PostRenderSegment {
  final _PostRenderSegmentType type;
  final int scrollIndex;
  final int postIndex;
  final Post post;
  final int? chunkIndex;
  final HtmlChunk? chunkData;
  final NewEngineLongPostData? newEngineData;
  final int gapCount; // gap 段中隐藏帖子的数量

  const _PostRenderSegment._({
    required this.type,
    required this.scrollIndex,
    required this.postIndex,
    required this.post,
    this.chunkIndex,
    this.chunkData,
    this.newEngineData,
    this.gapCount = 0,
  });
  factory _PostRenderSegment.shortPost({
    required int scrollIndex,
    required int postIndex,
    required Post post,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.shortPost,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
    );
  }

  factory _PostRenderSegment.header({
    required int scrollIndex,
    required int postIndex,
    required Post post,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.longHeader,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
    );
  }

  factory _PostRenderSegment.chunk({
    required int scrollIndex,
    required int postIndex,
    required Post post,
    required int chunkIndex,
    required HtmlChunk chunkData,
    NewEngineLongPostData? newEngineData,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.longChunk,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
      chunkIndex: chunkIndex,
      chunkData: chunkData,
      newEngineData: newEngineData,
    );
  }

  factory _PostRenderSegment.footer({
    required int scrollIndex,
    required int postIndex,
    required Post post,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.longFooter,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
    );
  }

  factory _PostRenderSegment.gapBefore({
    required int scrollIndex,
    required int postIndex,
    required Post post,
    required int gapCount,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.gapBefore,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
      gapCount: gapCount,
    );
  }

  factory _PostRenderSegment.gapAfter({
    required int scrollIndex,
    required int postIndex,
    required Post post,
    required int gapCount,
  }) {
    return _PostRenderSegment._(
      type: _PostRenderSegmentType.gapAfter,
      scrollIndex: scrollIndex,
      postIndex: postIndex,
      post: post,
      gapCount: gapCount,
    );
  }
}

/// Gap 指示器 - 显示被隐藏的帖子数量，点击后加载
class _GapIndicator extends StatefulWidget {
  final int count;
  final VoidCallback? onTap;

  const _GapIndicator({required this.count, this.onTap});

  @override
  State<_GapIndicator> createState() => _GapIndicatorState();
}

class _GapIndicatorState extends State<_GapIndicator> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: _loading
          ? null
          : () {
              setState(() => _loading = true);
              widget.onTap?.call();
            },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.3,
          ),
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_loading)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.emphasis.accent,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Symbols.unfold_more_rounded,
                  size: 16,
                  color: context.emphasis.accent,
                ),
              ),
            Text(
              _loading
                  ? S.current.topicDetail_loading
                  : S.current.topicDetail_showHiddenReplies(widget.count),
              style: theme.textTheme.labelMedium?.copyWith(
                color: context.emphasis.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 加载失败时的重试提示
class _LoadFailedRetry extends StatelessWidget {
  final VoidCallback? onRetry;

  const _LoadFailedRetry({this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: GestureDetector(
          onTap: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.refresh_rounded,
                size: 16,
                color: context.emphasis.accent,
              ),
              const SizedBox(width: 6),
              Text(
                S.current.topicDetail_loadFailedTapRetry,
                style: TextStyle(
                  fontSize: 14,
                  color: context.emphasis.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上下增量加载时的指示器
class _LoadMoreIndicator extends StatelessWidget {
  const _LoadMoreIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: LoadingSpinner(size: 24)),
    );
  }
}
