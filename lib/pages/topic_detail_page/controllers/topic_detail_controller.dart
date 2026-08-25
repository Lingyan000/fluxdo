import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../../../models/topic.dart';
import '../../../services/screen_track.dart';
import '../../../utils/scroll_jump.dart';

/// 话题详情页滚动状态
class TopicScrollState {
  final bool showBackToTop;
  final bool showBottomBar;
  final bool hasInitialScrolled;
  final bool isPositioned;
  final int? jumpTargetPostNumber;
  final int? initialCenterPostNumber;
  final int? viewportPostNumber;
  final int? keyboardSelectedPostNumber;

  const TopicScrollState({
    this.showBackToTop = false,
    this.showBottomBar = false,
    this.hasInitialScrolled = false,
    this.isPositioned = false,
    this.jumpTargetPostNumber,
    this.initialCenterPostNumber,
    this.viewportPostNumber,
    this.keyboardSelectedPostNumber,
  });

  TopicScrollState copyWith({
    bool? showBackToTop,
    bool? showBottomBar,
    bool? hasInitialScrolled,
    bool? isPositioned,
    int? jumpTargetPostNumber,
    int? initialCenterPostNumber,
    int? viewportPostNumber,
    int? keyboardSelectedPostNumber,
    bool clearJumpTarget = false,
    bool clearInitialCenter = false,
    bool clearKeyboardSelected = false,
  }) {
    return TopicScrollState(
      showBackToTop: showBackToTop ?? this.showBackToTop,
      showBottomBar: showBottomBar ?? this.showBottomBar,
      hasInitialScrolled: hasInitialScrolled ?? this.hasInitialScrolled,
      isPositioned: isPositioned ?? this.isPositioned,
      jumpTargetPostNumber: clearJumpTarget
          ? null
          : (jumpTargetPostNumber ?? this.jumpTargetPostNumber),
      initialCenterPostNumber: clearInitialCenter
          ? null
          : (initialCenterPostNumber ?? this.initialCenterPostNumber),
      viewportPostNumber: viewportPostNumber ?? this.viewportPostNumber,
      keyboardSelectedPostNumber: clearKeyboardSelected
          ? null
          : (keyboardSelectedPostNumber ?? this.keyboardSelectedPostNumber),
    );
  }
}

typedef PostSegmentRange = ({int firstScrollIndex, int lastScrollIndex});

/// 话题详情页控制器
/// 统一管理滚动状态、帖子高亮、可见性追踪
class TopicDetailController extends ChangeNotifier {
  // ============ 滚动相关 ============
  final AutoScrollController scrollController;
  final VoidCallback? onScrolled;

  TopicScrollState _scrollState;
  double _accumulatedScrollDelta = 0;

  /// 底部栏显示状态
  final ValueNotifier<bool> showBottomBarNotifier = ValueNotifier<bool>(false);

  /// 定位完成状态
  final ValueNotifier<bool> isPositionedNotifier = ValueNotifier<bool>(false);

  // ============ 高亮相关 ============
  int? _highlightPostNumber;
  Timer? _highlightTimer;

  /// 高亮帖子号
  final ValueNotifier<int?> highlightNotifier = ValueNotifier<int?>(null);

  /// 当前快捷键锚点对应的帖子号（键盘选中优先，否则回退到当前视口帖子）
  final ValueNotifier<int?> selectedPostNumberNotifier = ValueNotifier<int?>(
    null,
  );

  /// 待高亮的帖子号（等待列表可见后触发）
  int? pendingHighlightPostNumber;

  /// 是否跳过下一次跳转高亮
  bool skipNextJumpHighlight = false;

  // ============ 可见性相关 ============
  final ScreenTrack screenTrack;

  final Set<int> _visiblePostNumbers = {};
  final Set<int> _readPostNumbers = {};
  int _currentVisibleStreamIndex = 1;
  Map<int, int> _postIndexToScrollIndex = const {};
  Map<int, int> _scrollIndexToPostNumber = const {};
  Map<int, PostSegmentRange> _postSegmentRanges = const {};

  /// stream 索引
  final ValueNotifier<int> streamIndexNotifier = ValueNotifier<int>(1);

  /// 视口当前帖号(eyeline 上报)的细粒度通知 —— TOC 显隐门控等用;
  /// 独立 ValueNotifier 是因为滚动期它高频变化,不能走 ChangeNotifier
  /// 的 notifyListeners(会整树 rebuild)。
  final ValueNotifier<int?> viewportPostNumberNotifier =
      ValueNotifier<int?>(null);

  Timer? _screenTrackThrottleTimer;
  bool _trackEnabled;

  TopicDetailController({
    required this.scrollController,
    required this.screenTrack,
    required bool trackEnabled,
    this.onScrolled,
    int? initialPostNumber,
  }) : _trackEnabled = trackEnabled,
       _scrollState = TopicScrollState(jumpTargetPostNumber: initialPostNumber);

  // ============ 滚动状态 Getters ============

  TopicScrollState get scrollState => _scrollState;
  bool get showBackToTop => _scrollState.showBackToTop;
  bool get showBottomBar => _scrollState.showBottomBar;
  bool get hasInitialScrolled => _scrollState.hasInitialScrolled;
  bool get isPositioned => _scrollState.isPositioned;
  int? get jumpTargetPostNumber => _scrollState.jumpTargetPostNumber;
  int? get initialCenterPostNumber => _scrollState.initialCenterPostNumber;
  int? get viewportPostNumber => _scrollState.viewportPostNumber;
  int? get keyboardSelectedPostNumber =>
      _scrollState.keyboardSelectedPostNumber;
  int? get effectivePostNumberForActions =>
      keyboardSelectedPostNumber ?? viewportPostNumber;

  // ============ 高亮状态 Getters ============

  int? get highlightPostNumber => _highlightPostNumber;

  // ============ 可见性状态 Getters ============

  Set<int> get visiblePostNumbers => Set.unmodifiable(_visiblePostNumbers);
  int get currentVisibleStreamIndex => _currentVisibleStreamIndex;

  int scrollIndexForPostIndex(int postIndex) {
    return _postIndexToScrollIndex[postIndex] ?? postIndex;
  }

  int? postNumberForScrollIndex(int scrollIndex) {
    return _scrollIndexToPostNumber[scrollIndex];
  }

  PostSegmentRange? segmentRangeForPost(int postNumber) {
    return _postSegmentRanges[postNumber];
  }

  bool get trackEnabled => _trackEnabled;
  set trackEnabled(bool value) {
    if (_trackEnabled != value) {
      _trackEnabled = value;
      if (!_trackEnabled) {
        screenTrack.stop();
      }
    }
  }

  int? get topVisiblePostNumber {
    if (_visiblePostNumbers.isEmpty) return null;
    return _visiblePostNumbers.reduce((a, b) => a < b ? a : b);
  }

  int? get bottomVisiblePostNumber {
    if (_visiblePostNumbers.isEmpty) return null;
    return _visiblePostNumbers.reduce((a, b) => a > b ? a : b);
  }

  // ============ 滚动方法 ============

  void _updateScrollState(TopicScrollState newState) {
    if (_scrollState != newState) {
      if (_scrollState.showBottomBar != newState.showBottomBar) {
        showBottomBarNotifier.value = newState.showBottomBar;
      }
      if (_scrollState.isPositioned != newState.isPositioned) {
        isPositionedNotifier.value = newState.isPositioned;
      }
      _scrollState = newState;
      notifyListeners();
    }
  }

  /// 处理滚动事件
  void handleScroll() {
    onScrolled?.call();

    // center 坐标系下 before 区是负 offset，"离顶距离"须相对 minScrollExtent
    final shouldShowBackToTop =
        scrollController.hasClients &&
        scrollController.position.pixels -
                scrollController.position.minScrollExtent >
            300;
    if (shouldShowBackToTop != _scrollState.showBackToTop) {
      _updateScrollState(
        _scrollState.copyWith(showBackToTop: shouldShowBackToTop),
      );
    }

    // 滚动时触发进度更新（位置刷新在节流回调内执行）
    _throttledUpdateScreenTrack();
  }

  /// 处理滚动通知，精确检测用户主动滚动
  bool handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _handleBottomBarScrollDelta(notification.scrollDelta ?? 0);
    }

    if (notification is ScrollEndNotification) {
      _accumulatedScrollDelta = 0;
    }

    return false;
  }

  /// 处理桌面端鼠标滚轮/触控板滚动，避免依赖 dragDetails。
  void handlePointerScroll(double delta) {
    _handleBottomBarScrollDelta(delta);
  }

  void _handleBottomBarScrollDelta(double delta) {
    if (delta == 0) return;

    if ((_accumulatedScrollDelta > 0 && delta < 0) ||
        (_accumulatedScrollDelta < 0 && delta > 0)) {
      _accumulatedScrollDelta = delta;
    } else {
      _accumulatedScrollDelta += delta;
    }

    const threshold = 50.0;
    if (_accumulatedScrollDelta < -threshold && !_scrollState.showBottomBar) {
      _scrollState = _scrollState.copyWith(showBottomBar: true);
      showBottomBarNotifier.value = true;
      _accumulatedScrollDelta = 0;
    } else if (_accumulatedScrollDelta > threshold &&
        _scrollState.showBottomBar) {
      _scrollState = _scrollState.copyWith(showBottomBar: false);
      showBottomBarNotifier.value = false;
      _accumulatedScrollDelta = 0;
    }
  }

  /// 找到中心点位置
  int findCenterPostIndex(List<Post> posts) {
    if (_scrollState.initialCenterPostNumber == null || posts.isEmpty) return 0;
    for (int i = 0; i < posts.length; i++) {
      if (posts[i].postNumber >= _scrollState.initialCenterPostNumber!) {
        return i;
      }
    }
    return 0;
  }

  /// 滚动到指定帖子（近距跳转，目标已渲染），返回是否收敛到布局范围。
  ///
  /// 用 jumpTo 而非 animateTo：动画窗口内维度收缩会留下越界位置，
  /// 触底回弹的成因见 [AutoScrollJump.jumpToRenderedScrollIndex]。
  Future<bool> scrollToPost(int postNumber, List<Post> posts) async {
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);
    if (postIndex == -1) return false;

    final scrollIndex = scrollIndexForPostIndex(postIndex);
    await scrollController.jumpToRenderedScrollIndex(scrollIndex);
    return scrollController.isIndexStateInLayoutRange(scrollIndex);
  }

  /// 滚动到长帖的指定 chunk 段（TOC 标题跳转用）。
  ///
  /// [chunkIndex] 为 null 时等同 [scrollToPost]（短帖整帖一段）;
  /// 长帖分段序为 header + chunk×N + footer,目标段 = 帖首段 + 1 + chunk。
  Future<bool> scrollToPostChunk(
    int postNumber,
    int? chunkIndex,
    List<Post> posts,
  ) async {
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);
    if (postIndex == -1) return false;

    var scrollIndex = scrollIndexForPostIndex(postIndex);
    if (chunkIndex != null) scrollIndex += 1 + chunkIndex;
    await scrollController.jumpToRenderedScrollIndex(scrollIndex);
    return scrollController.isIndexStateInLayoutRange(scrollIndex);
  }

  /// 回到顶部
  Future<void> scrollToTop() async {
    if (!scrollController.hasClients) return;

    scrollController.animateTo(
      scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 检查是否需要加载更早的帖子
  bool shouldLoadPrevious(bool hasMoreBefore, bool isLoadingPrevious) {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    final isOverscrollingTop = position.pixels < position.minScrollExtent;
    return !isOverscrollingTop &&
        position.pixels <= position.minScrollExtent + 200 &&
        hasMoreBefore &&
        !isLoadingPrevious;
  }

  /// 检查是否需要加载更多
  bool shouldLoadMore(bool hasMoreAfter, bool isLoadingMore) {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    return position.pixels >= position.maxScrollExtent - 500 &&
        hasMoreAfter &&
        !isLoadingMore;
  }

  /// 准备跳转到帖子（重新加载数据）
  void prepareJumpToPost(int postNumber) {
    _updateScrollState(
      TopicScrollState(
        showBackToTop: _scrollState.showBackToTop,
        showBottomBar: _scrollState.showBottomBar,
        hasInitialScrolled: false,
        isPositioned: false,
        jumpTargetPostNumber: postNumber,
        initialCenterPostNumber: null,
        viewportPostNumber: _scrollState.viewportPostNumber,
        keyboardSelectedPostNumber: postNumber,
      ),
    );
  }

  /// 准备刷新
  void prepareRefresh(int anchorPostNumber, {bool skipHighlight = false}) {
    _updateScrollState(
      TopicScrollState(
        showBackToTop: _scrollState.showBackToTop,
        showBottomBar: _scrollState.showBottomBar,
        hasInitialScrolled: false,
        isPositioned: _scrollState.isPositioned,
        jumpTargetPostNumber: anchorPostNumber,
        initialCenterPostNumber: null,
        viewportPostNumber: _scrollState.viewportPostNumber,
        keyboardSelectedPostNumber: _scrollState.keyboardSelectedPostNumber,
      ),
    );
    if (skipHighlight) {
      skipNextJumpHighlight = true;
    }
  }

  /// 标记初始滚动完成
  void markInitialScrolled(int firstPostNumber) {
    if (_scrollState.initialCenterPostNumber != null) {
      _updateScrollState(_scrollState.copyWith(hasInitialScrolled: true));
    } else {
      _updateScrollState(
        _scrollState.copyWith(
          hasInitialScrolled: true,
          initialCenterPostNumber: firstPostNumber,
        ),
      );
    }
  }

  /// 标记定位完成
  void markPositioned() {
    if (!_scrollState.isPositioned) {
      _scrollState = _scrollState.copyWith(isPositioned: true);
      isPositionedNotifier.value = true;
    }
  }

  /// 清除跳转目标
  void clearJumpTarget() {
    _updateScrollState(_scrollState.copyWith(clearJumpTarget: true));
  }

  /// 检查帖子是否已渲染
  bool isPostRendered(int postIndex) {
    return scrollController.tagMap.containsKey(
      scrollIndexForPostIndex(postIndex),
    );
  }

  void updateScrollIndexMapping(Map<int, int> mapping) {
    _postIndexToScrollIndex = Map.unmodifiable(mapping);
  }

  /// 本地跳转到帖子（不重新请求，仅重置视图中心）
  void jumpToPostLocally(int postNumber) {
    // 重置可见性数据
    resetVisibility();

    _updateScrollState(
      _scrollState.copyWith(
        hasInitialScrolled: false,
        isPositioned: false,
        jumpTargetPostNumber: postNumber,
        initialCenterPostNumber: postNumber,
        keyboardSelectedPostNumber: postNumber,
      ),
    );
  }

  // ============ 高亮方法 ============

  /// 触发高亮效果
  void triggerHighlight(int postNumber) {
    _highlightPostNumber = postNumber;
    highlightNotifier.value = postNumber;

    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      _highlightPostNumber = null;
      highlightNotifier.value = null;
    });
  }

  /// 清除高亮
  void clearHighlight() {
    _highlightTimer?.cancel();
    _highlightPostNumber = null;
    pendingHighlightPostNumber = null;
    highlightNotifier.value = null;
  }

  /// 消费待高亮帖子号并触发高亮
  void consumePendingHighlight() {
    if (pendingHighlightPostNumber != null) {
      final target = pendingHighlightPostNumber!;
      pendingHighlightPostNumber = null;
      skipNextJumpHighlight = false;
      triggerHighlight(target);
    }
  }

  // ============ 可见性方法 ============

  /// 更新可见帖子集合（由 SliverViewObserver 驱动）
  void updateVisiblePosts(Set<int> visiblePostNumbers) {
    if (setEquals(_visiblePostNumbers, visiblePostNumbers)) return;
    _visiblePostNumbers
      ..clear()
      ..addAll(visiblePostNumbers);
    _throttledUpdateScreenTrack();
  }

  void setReadPostNumbers(Set<int> readPostNumbers) {
    if (setEquals(_readPostNumbers, readPostNumbers)) return;
    _readPostNumbers
      ..clear()
      ..addAll(readPostNumbers);
    _throttledUpdateScreenTrack();
  }

  void _throttledUpdateScreenTrack() {
    if (_screenTrackThrottleTimer?.isActive ?? false) return;
    _screenTrackThrottleTimer = Timer(const Duration(milliseconds: 16), () {
      if (_trackEnabled) {
        final readOnscreen = _visiblePostNumbers.intersection(_readPostNumbers);
        screenTrack.setOnscreen(
          _visiblePostNumbers,
          readOnscreen: readOnscreen,
        );
      }
    });
  }

  /// 更新当前视口帖子（由 eyeline 可见性变化驱动）
  void updateViewportPostNumber(int postNumber) {
    if (_scrollState.viewportPostNumber != postNumber) {
      _scrollState = _scrollState.copyWith(viewportPostNumber: postNumber);
      viewportPostNumberNotifier.value = postNumber;
    }
  }

  /// 更新键盘当前选中的帖子（J/K 导航锚点）
  void selectKeyboardPostNumber(int? postNumber) {
    if (_scrollState.keyboardSelectedPostNumber == postNumber) {
      return;
    }

    _scrollState = postNumber == null
        ? _scrollState.copyWith(clearKeyboardSelected: true)
        : _scrollState.copyWith(keyboardSelectedPostNumber: postNumber);
  }

  /// 更新“键盘选中帖”的可视标识。
  ///
  /// 该标识只在 J/K 等键盘移动选择时显示，不跟随普通滚动或非快捷键跳转。
  void updateSelectedPostIndicator(int? postNumber) {
    if (selectedPostNumberNotifier.value == postNumber) return;
    selectedPostNumberNotifier.value = postNumber;
  }

  /// 更新 stream 索引
  void updateStreamIndex(int newIndex) {
    if (newIndex != _currentVisibleStreamIndex) {
      _currentVisibleStreamIndex = newIndex;
      streamIndexNotifier.value = newIndex;
    }
  }

  /// 更新滚动索引到帖子号的映射（长帖子分段导航使用）
  void updateScrollIndexToPostNumber(Map<int, int> mapping) {
    _scrollIndexToPostNumber = mapping;
  }

  /// 更新帖子对应的 segment 范围（长帖子分段导航使用）
  void updatePostSegmentRanges(Map<int, PostSegmentRange> ranges) {
    _postSegmentRanges = ranges;
  }

  /// 获取刷新时的锚点帖子号
  int getRefreshAnchorPostNumber(int? fallbackPostNumber) {
    if (_visiblePostNumbers.isNotEmpty) {
      return _visiblePostNumbers.reduce((a, b) => a < b ? a : b);
    }
    return viewportPostNumber ?? fallbackPostNumber ?? 1;
  }

  /// 重置可见性数据
  void resetVisibility() {
    _visiblePostNumbers.clear();
    _screenTrackThrottleTimer?.cancel();
  }

  @override
  void dispose() {
    // 滚动相关
    showBottomBarNotifier.dispose();
    isPositionedNotifier.dispose();
    scrollController.dispose();

    // 高亮相关
    _highlightTimer?.cancel();
    highlightNotifier.dispose();
    selectedPostNumberNotifier.dispose();

    // 可见性相关
    _screenTrackThrottleTimer?.cancel();
    streamIndexNotifier.dispose();
    viewportPostNumberNotifier.dispose();

    super.dispose();
  }
}
