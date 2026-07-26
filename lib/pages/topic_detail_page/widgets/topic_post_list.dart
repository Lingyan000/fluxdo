import 'dart:async' show Timer;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, Priority;
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
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
import '../../../widgets/common/anchor_guard_sliver.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show BlockNode, HtmlChunk, ParagraphWarmup, ParagraphWarmupProbe;
import '../../../widgets/post/post_item/post_item.dart';
import '../../../widgets/post/post_item/render_parse_cache.dart';
import '../../../widgets/post/post_item/segmented_long_post.dart';
import '../../../widgets/post/quote_image_scope.dart';
import 'topic_detail_header.dart';
import 'shared_issue_button.dart';
import 'typing_indicator.dart';
import 'pending_posts_section.dart';

/// 话题帖子列表
/// 负责构建 CustomScrollView 及其 Slivers
///
/// Before-center 和 after-center 帖子使用 SliverList.builder 实现虚拟化：
/// Flutter 会在 item 离开 viewport + cacheExtent 范围时自动 dispose 对应 widget，
/// 释放视频播放器、WebView 等资源。
/// 长帖子内部的 HTML 分块由 ChunkedHtmlContent 的 Column + SelectionArea 处理，
/// 保留跨块文本选择能力。
class TopicPostList extends StatefulWidget {
  final TopicDetail detail;
  final AutoScrollController scrollController;
  final GlobalKey centerKey;
  final GlobalKey headerKey;

  /// 视口 anchor（0 = center 顶对齐；>0 时 center 零点下移，
  /// 用于目标帖靠近话题末尾时的底部贴齐）
  final double viewportAnchor;
  final int? selectedPostNumber;
  final int? highlightPostNumber;
  final bool isLoggedIn;
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
  final int centerPostIndex;
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

  const TopicPostList({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.centerKey,
    required this.headerKey,
    this.viewportAnchor = 0.0,
    required this.selectedPostNumber,
    required this.highlightPostNumber,
    this.highlightBoostUsername,
    this.hideHeaderTitle = false,
    required this.isLoggedIn,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.loadingPreviousListenable,
    required this.loadingMoreListenable,
    required this.loadMoreFailedListenable,
    required this.loadPreviousFailedListenable,
    this.onRetryLoadMore,
    this.onRetryLoadPrevious,
    required this.centerPostIndex,
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
    this.onPointerScroll,
    this.onFillGapBefore,
    this.onFillGapAfter,
    this.onExpandHiddenPost,
    this.useReplyDialog = false,
    this.onShowPostDetail,
    this.onWithdrawPendingPost,
    this.onWithdrawAndEditPendingPost,
  });

  @override
  State<TopicPostList> createState() => _TopicPostListState();
}

class _TopicPostListState extends State<TopicPostList> {
  int? _lastReportedPostNumber;
  bool _isThrottled = false;

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

  /// segments 结构签名:增删帖/翻页/gap 填充/长帖分块数变化都会改变它,
  /// 锚定哨兵据此作废基线(sliver child 按 index 复用,结构变化 = 同一
  /// RenderBox 换内容,不能再按旧基线修正)。纯数据更新(点赞等)不改。
  int _segmentsStructureHash = 0;
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

  /// 渐进物化上限(段数,null = 不限制)。before/after 两条 SliverList
  /// 各一份:翻页只发生在一侧,单值会误截另一侧已物化的段。
  ///
  /// 生产归因日志:数据到达帧一次物化 viewport+cacheExtent 内的 8~10 帖,
  /// build 25~29ms(120Hz 预算 8.3ms)。两个时机启用:
  /// - 挂载初期:首帧 2 段起步;滚动繁忙时每帧 +1,空闲时 +2,
  ///   追平即置 null。列表只向外增长,已布局项不动、零跳变。
  /// - 翻页落地:尾部追加/头部插入大量新段时对新增侧重启(旧段数 +
  ///   当前步长起步,cap ≥ 旧 childCount,已物化段绝不被卸载),见
  ///   [_maybeStartPagingMaterialize];gap 填充/整页替换不启用。
  int? _materializeCapBefore;
  int? _materializeCapAfter;
  bool _materializeTicking = false;
  static const int _materializeBusyStep = 1;
  static const int _materializeIdleStep = 2;
  static const int _materializeMinPagingSegments = 8;

  int get _currentMaterializeStep =>
      ScrollBusySignal.isBusy ? _materializeBusyStep : _materializeIdleStep;

  void _scheduleMaterializeStep() {
    if (_materializeTicking) return;
    _materializeTicking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _materializeTicking = false;
      if (!mounted) return;
      final centerScrollIndex =
          _postIndexToScrollIndex[widget.centerPostIndex] ?? 0;
      final step = _currentMaterializeStep;
      var advanced = false;

      final capBefore = _materializeCapBefore;
      if (capBefore != null) {
        if (capBefore >= centerScrollIndex) {
          // childCount 已是全量(min 取总数),置 null 无需重建
          _materializeCapBefore = null;
        } else {
          _materializeCapBefore = capBefore + step;
          advanced = true;
        }
      }

      final capAfter = _materializeCapAfter;
      if (capAfter != null) {
        final afterTotal = _renderSegments.length - centerScrollIndex;
        if (capAfter >= afterTotal) {
          _materializeCapAfter = null;
        } else {
          _materializeCapAfter = capAfter + step;
          advanced = true;
        }
      }

      if (advanced) {
        setState(() {});
        _scheduleMaterializeStep();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // 首屏渐进物化:顶部/跳转进入都启用。跳转进入时 center 在 after
    // 列表 index 0、before 列表 index 0 离 center 最近 —— cap 截断的
    // 都是两侧**远端**,center 及近邻首帧即物化,定位不受影响。
    _materializeCapBefore = _materializeIdleStep;
    _materializeCapAfter = _materializeIdleStep;
    _scheduleMaterializeStep();
    // 首帧渲染后触发一次可见性检测，确保进入页面时即上报阅读状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateFirstVisiblePost();
      }
    });
    // 滚动回跳探针:捕捉"滚动中内容被反向拉回"。单帧内 offset 反向
    // 跳变通常来自布局高度记账不一致触发的 scroll offset correction
    // (双向列表 before-center 楼层重挂载时高度与上次不同等)。
    // 事件经 FrameJankMonitor 汇入诊断时间轴(监控关闭时零输出),
    // listener 本体每帧只做几次数值比较,release 常驻注册无碍。
    widget.scrollController.addListener(_scrollJumpProbe);
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
    widget.scrollController.removeListener(_scrollJumpProbe);
    _parseWarmUpRetry?.cancel();
    super.dispose();
  }

  // 便捷 getter，简化 widget.xxx 访问
  TopicDetail get detail => widget.detail;
  AutoScrollController get scrollController => widget.scrollController;
  GlobalKey get centerKey => widget.centerKey;
  GlobalKey get headerKey => widget.headerKey;
  int? get selectedPostNumber => widget.selectedPostNumber;
  int? get highlightPostNumber => widget.highlightPostNumber;
  bool get isLoggedIn => widget.isLoggedIn;
  bool get hasMoreBefore => widget.hasMoreBefore;
  bool get hasMoreAfter => widget.hasMoreAfter;
  VoidCallback? get onRetryLoadMore => widget.onRetryLoadMore;
  VoidCallback? get onRetryLoadPrevious => widget.onRetryLoadPrevious;
  int get centerPostIndex => widget.centerPostIndex;
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

  /// 处理滚动通知，同时更新可见帖子
  bool _handleScrollNotification(ScrollNotification notification) {
    // 先调用原有的滚动通知处理
    final result = onScrollNotification(notification);

    // 在滚动更新时检测可见帖子（节流 16ms）
    if (notification is ScrollUpdateNotification && !_isThrottled) {
      _isThrottled = true;
      Future.delayed(const Duration(milliseconds: 16), () {
        if (mounted) {
          _isThrottled = false;
          _updateFirstVisiblePost();
        }
      });
    } else if (notification is ScrollEndNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateFirstVisiblePost();
        }
      });
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
        SchedulerBinding.instance.scheduleTask(() {
          if (!mounted || generation != _warmUpGeneration) return;
          pending!.warmUpOneChunk();
          step();
        }, Priority.idle);
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
    SchedulerBinding.instance.scheduleTask(() {
      if (!mounted || generation != _warmUpGeneration) return;
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
        _warmPostCursor =
            (idx >= 0 && idx + 1 < posts.length) ? posts[idx + 1].id : null;
        _warmNodeCursor = 0;
        if (_warmPostCursor == null) return; // 到底了
      } else {
        _warmPostCursor = postId;
        _warmNodeCursor = next;
      }
      _scheduleParagraphWarmUp(generation); // 下一 idle 步
    }, Priority.idle);
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
        return 'post-${segment.post.id}';
      case _PostRenderSegmentType.longHeader:
        return 'long-header-${segment.post.id}';
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
    final oldSegmentsLength = _renderSegments.length;
    final oldIndexMap = _postIndexToScrollIndex;
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
      final useLongSegments = longChunks.isNotEmpty;

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
    var structureHash = 0;
    for (final s in segments) {
      structureHash = Object.hash(
        structureHash,
        s.type,
        s.post.id,
        s.chunkIndex ?? -1,
      );
    }
    _segmentsStructureHash = structureHash;
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
    _maybeStartPagingMaterialize(
      oldPosts,
      posts,
      oldSegmentsLength,
      oldIndexMap,
    );
  }

  /// 翻页落地的渐进物化 + 新帖解析预热。
  ///
  /// loadMore/loadPrevious 一次落地十几帖时,落在 cacheExtent 内的新段
  /// 会被同帧全部物化(单帖 build 6~20ms,叠加即 UI 大帧/STALL 的组成
  /// 部分)。检测"尾部追加/头部插入"型结构变化,对新增侧重启渐进
  /// cap:旧段数 + 当前步长起步(≥ 旧 childCount,已物化段绝不被卸载),
  /// 滚动繁忙时每帧 +1、空闲时 +2 追平。中间 gap 填充(首尾都不变)
  /// 与整页替换(首尾都变)不启用,维持旧行为。
  void _maybeStartPagingMaterialize(
    List<Post>? oldPosts,
    List<Post> newPosts,
    int oldSegmentsLength,
    Map<int, int> oldIndexMap,
  ) {
    if (oldPosts == null || oldPosts.isEmpty || oldSegmentsLength == 0) return;
    if (newPosts.length <= oldPosts.length) return;
    final sameFirst = newPosts.first.id == oldPosts.first.id;
    final sameLast = newPosts.last.id == oldPosts.last.id;
    if (sameFirst == sameLast) return; // gap 填充(都同)/整页替换(都变)

    final addedSegments = _renderSegments.length - oldSegmentsLength;
    final fewAdded = addedSegments < _materializeMinPagingSegments;

    if (sameFirst) {
      // 尾部追加:append 不改 center 的 postIndex 与 scrollIndex
      if (!fewAdded && _materializeCapAfter == null) {
        final oldCenter = oldIndexMap[widget.centerPostIndex] ?? 0;
        final oldAfterCount = oldSegmentsLength - oldCenter;
        if (oldAfterCount >= 0) {
          _materializeCapAfter = oldAfterCount + _currentMaterializeStep;
          _scheduleMaterializeStep();
          // 汇入诊断时间轴:对照 SCROLL-PROBE,定案"内容区回跳是否
          // 与 cap 渐进窗口(extent 逐帧长全)重合"
          FrameJankMonitor.logEvent(
            'MATERIALIZE',
            'after cap=$_materializeCapAfter +$addedSegments段',
          );
        }
      }
      _schedulePostParseWarmUp(newPosts.sublist(oldPosts.length));
    } else {
      // 头部插入:prepend 使 centerPostIndex 平移了新增帖数
      final shift = newPosts.length - oldPosts.length;
      if (!fewAdded && _materializeCapBefore == null) {
        final oldCenter = oldIndexMap[widget.centerPostIndex - shift];
        if (oldCenter != null) {
          _materializeCapBefore = oldCenter + _currentMaterializeStep;
          _scheduleMaterializeStep();
          FrameJankMonitor.logEvent(
            'MATERIALIZE',
            'before cap=$_materializeCapBefore +$addedSegments段',
          );
        }
      }
      _schedulePostParseWarmUp(newPosts.sublist(0, shift));
    }
  }

  /// 新落地帖子的解析预热:idle 时间逐帖跑 [RenderParseCache.shortPost]
  /// (preprocess + DOM parse,单帖 1~5ms),配合渐进 cap 后,物化帧只剩
  /// 纯 widget 构建。长帖跳过(chunk 懒解析 + 滚动停止后的
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
      SchedulerBinding.instance.scheduleTask(() {
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
      }, Priority.idle);
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
    _buildRenderSegments(posts);
    final centerScrollIndex = _postIndexToScrollIndex[centerPostIndex] ?? 0;
    // 锚定哨兵的结构签名:segments 结构 + center 分割点(center 变化会让
    // before/after 两个 SliverList 的 index↔内容映射整体重排)
    final anchorSignature = Object.hash(
      _segmentsStructureHash,
      centerScrollIndex,
    );

    // 不再包系统 SelectionArea:正文选区全部由 FluxdoRender 自研选区承担
    // (含未登录场景 —— toolbar 降级只留「复制」)。header/footer 等普通
    // Widget 不创建系统选区节点,省掉手势竞技场竞争与 registrar 树维护。
    //
    // QuoteImageScope:图片长按菜单的「引用」handler 在 tap 时刻就近现取
    // (flatten 产物进全局缓存后,callbacks 闭包里的冻结引用可能指向已
    // 销毁页面的 State,见 QuoteImageScope 文档)。
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
        child: CustomScrollView(
          controller: scrollController,
          center: centerKey,
          anchor: widget.viewportAnchor,
          scrollCacheExtent: ScrollCacheExtent.pixels(
            Responsive.isMobile(context) ? 300 : 500,
          ),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            // 滚动锚定哨兵(before 区):位于 center 之前 = reverse 增长区,
            // 该区布局序从近 center 向外推进,首位哨兵最后布局,能读到
            // 本区兄弟的新鲜位置。作用见 AnchorGuardSliver 文档。
            AnchorGuardSliver(structureSignature: anchorSignature),
            // 向上加载骨架屏 / 失败重试(ListenableBuilder 就地切换,
            // 分页起止只重建这一个 sliver,不整页 rebuild)
            if (hasMoreBefore)
              ListenableBuilder(
                listenable: Listenable.merge([
                  widget.loadingPreviousListenable,
                  widget.loadPreviousFailedListenable,
                ]),
                builder: (context, _) {
                  if (widget.loadPreviousFailedListenable.value) {
                    return SliverToBoxAdapter(
                      child: _LoadFailedRetry(onRetry: onRetryLoadPrevious),
                    );
                  }
                  if (widget.loadingPreviousListenable.value) {
                    return SliverToBoxAdapter(
                      child: _wrapContent(context, const _LoadMoreIndicator()),
                    );
                  }
                  return const SliverToBoxAdapter(child: SizedBox.shrink());
                },
              ),

            // 话题 Header（centerPostIndex > 0 时放在 before-center 区域）
            if (hasFirstPost && centerPostIndex > 0)
              SliverToBoxAdapter(
                child: _wrapContent(
                  context,
                  TopicDetailHeader(
                    detail: detail,
                    headerKey: headerKey,
                    showTitle: !widget.hideHeaderTitle,
                    onVoteChanged: onVoteChanged,
                    onNotificationLevelChanged: onNotificationLevelChanged,
                    onJumpToPost: onJumpToPost,
                  ),
                ),
              ),

            // Before-center 帖子（SliverList.builder 实现虚拟化回收）
            // center 之前的 sliver 向上增长，index 0 离 center 最近，需要反转映射
            if (centerPostIndex > 0)
              SliverList.builder(
                // 渐进物化:cap 截断的是远离 center 的上方远端
                itemCount: _materializeCapBefore == null
                    ? centerScrollIndex
                    : (_materializeCapBefore! < centerScrollIndex
                          ? _materializeCapBefore!
                          : centerScrollIndex),
                itemBuilder: (context, index) {
                  final segmentIndex = centerScrollIndex - 1 - index;
                  return _buildSegmentItem(
                    context,
                    _renderSegments[segmentIndex],
                  );
                },
              ),

            // 中心帖子 + after-center 帖子（合并为一个 SliverList.builder）
            // SliverList 不会回收最后一个 child，所以必须合并，确保 center 帖子
            // 是多 item 列表中的一项，滚出视口后能被正常回收。
            // centerPostIndex == 0 且有 header 时，用 SliverMainAxisGroup 将
            // header 和帖子列表组合为 center，保证 header 默认可见。
            if (centerPostIndex == 0 && hasFirstPost)
              SliverMainAxisGroup(
                key: centerKey,
                slivers: [
                  SliverToBoxAdapter(
                    child: _wrapContent(
                      context,
                      TopicDetailHeader(
                        detail: detail,
                        headerKey: headerKey,
                        showTitle: !widget.hideHeaderTitle,
                        onVoteChanged: onVoteChanged,
                        onNotificationLevelChanged: onNotificationLevelChanged,
                        onJumpToPost: onJumpToPost,
                      ),
                    ),
                  ),
                  SliverList.builder(
                    // 首屏渐进物化:挂载初期逐帧放开(见 _materializeCap)
                    itemCount: _materializeCapAfter == null
                        ? _renderSegments.length
                        : (_materializeCapAfter! < _renderSegments.length
                              ? _materializeCapAfter!
                              : _renderSegments.length),
                    itemBuilder: (context, index) =>
                        _buildSegmentItem(context, _renderSegments[index]),
                  ),
                ],
              )
            else
              SliverList.builder(
                key: centerKey,
                // 渐进物化:center 是本列表 index 0,cap 截断下方远端
                itemCount: () {
                  final total = _renderSegments.length - centerScrollIndex;
                  final cap = _materializeCapAfter;
                  return cap == null || cap >= total ? total : cap;
                }(),
                itemBuilder: (context, index) {
                  final segmentIndex = centerScrollIndex + index;
                  return _buildSegmentItem(
                    context,
                    _renderSegments[segmentIndex],
                  );
                },
              ),

            // 当前用户的待审核回复(帖子流末尾,仅本人可见;对齐官方
            // topic 模板的 pending-posts 块)。位于分页边界内侧:还有
            // 更多帖子未加载时不显示,避免"待审"出现在中间位置。
            if (!hasMoreAfter &&
                detail.pendingPosts.isNotEmpty &&
                widget.onWithdrawPendingPost != null &&
                widget.onWithdrawAndEditPendingPost != null)
              SliverToBoxAdapter(
                child: _wrapContent(
                  context,
                  PendingPostsSection(
                    pendingPosts: detail.pendingPosts,
                    onWithdraw: widget.onWithdrawPendingPost!,
                    onWithdrawAndEdit: widget.onWithdrawAndEditPendingPost!,
                  ),
                ),
              ),

            // 正在输入指示器（始终占位，通过 AnimatedSize 平滑过渡避免列表抖动）
            // Consumer 放在 sliver 内部：typingUsers 变化只重建这一行头像，
            // 不连累整个列表（此前 watch 在页面层，presence 消息 = 整列表 rebuild）
            if (!hasMoreAfter)
              SliverToBoxAdapter(
                child: _wrapContent(
                  context,
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    alignment: Alignment.topCenter,
                    child: Consumer(
                      builder: (context, ref, _) {
                        final typingUsers = ref.watch(
                          topicChannelProvider(
                            detail.id,
                          ).select((s) => s.typingUsers),
                        );
                        // 汇入性能诊断时间轴:"有人正在输入"场景的
                        // 卡顿是否与 presence/typing 更新同时刻。
                        // 同值去重:presence 消息风暴下重复的
                        // "0 users" 只会淹没时间轴,不携带信息
                        if (typingUsers.length != _lastLoggedTypingCount) {
                          _lastLoggedTypingCount = typingUsers.length;
                          FrameJankMonitor.logEvent(
                            'TYPING',
                            '${typingUsers.length} users',
                          );
                        }
                        return TypingAvatars(users: typingUsers);
                      },
                    ),
                  ),
                ),
              ),

            // 底部加载骨架屏 / 失败重试(同顶部,分页起止只重建本 sliver)
            if (hasMoreAfter)
              ListenableBuilder(
                listenable: Listenable.merge([
                  widget.loadingMoreListenable,
                  widget.loadMoreFailedListenable,
                ]),
                builder: (context, _) {
                  if (widget.loadMoreFailedListenable.value) {
                    return SliverToBoxAdapter(
                      child: _LoadFailedRetry(onRetry: onRetryLoadMore),
                    );
                  }
                  if (widget.loadingMoreListenable.value) {
                    return SliverToBoxAdapter(
                      child: _wrapContent(context, const _LoadMoreIndicator()),
                    );
                  }
                  return const SliverToBoxAdapter(child: SizedBox.shrink());
                },
              ),
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: 80 + MediaQuery.of(context).padding.bottom,
              ),
            ),
            // 滚动锚定哨兵(center/after 区):全局最后布局,守护 forward
            // 区的空闲期高度变化(before 区约束不含对面区尺寸,单哨兵会
            // 对 forward 区变化失明,故首尾各一)
            AnchorGuardSliver(structureSignature: anchorSignature),
          ],
        ),
      ),
    ),
    );
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
          topicTitle: detail.title,
          isPrivateMessageTopic: detail.isPrivateMessage,
          isPmWithNonHumanUser: detail.pmWithNonHumanUser,
          onShowPostDetail: widget.onShowPostDetail != null
              ? () => widget.onShowPostDetail!(post)
              : null,
          opTopSlot: opSlot,
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
        builder: (context, animation) => child,
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
                    color: theme.colorScheme.primary,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Symbols.unfold_more_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ),
            Text(
              _loading
                  ? S.current.topicDetail_loading
                  : S.current.topicDetail_showHiddenReplies(widget.count),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
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
    final theme = Theme.of(context);
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
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                S.current.topicDetail_loadFailedTapRetry,
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.primary,
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
