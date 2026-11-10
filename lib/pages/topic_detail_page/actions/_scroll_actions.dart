part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 滚动和导航相关方法
extension _ScrollActions on _TopicDetailPageState {
  void _onScroll() {
    if (_isRefreshing) return;

    _scheduleCheckTitleVisibility();
    _controller.handleScroll();
    // TOC scroll-spy(内部节流;无目录时零开销)
    _tocController.scheduleSpyUpdate();
    if (_isNestedView) return;

    final params = _params;
    final detailAsync = ref.read(topicDetailProvider(params));

    if (detailAsync.isLoading) return;

    // 数据通知与列表重建之间可能隔一帧，先等待该批数据完成布局，
    // 再用新的视口边界判断是否需要下一页。
    final detail = detailAsync.value;
    if (detail != null &&
        _controller.displayedPostCount !=
            _filteredDetail(detail).postStream.posts.length) {
      return;
    }

    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (_controller.shouldLoadPrevious(
      notifier.hasMoreBefore,
      notifier.isLoadingPrevious,
    )) {
      notifier.loadPrevious();
    }

    if (_controller.shouldLoadMore(
      notifier.hasMoreAfter,
      notifier.isLoadingMore,
    )) {
      notifier.loadMore();
    }
  }

  void _updateStreamIndexForPostNumber(int postNumber) {
    // 初始定位完成前，eyeline 上报的可能是定位途中经过的楼层，
    // 会让进度条数字从低楼层爬升、污染视口位置记录。
    // 暂存最后一次上报（TopicPostList 有去重，定位后同楼层不会重发），
    // 待定位完成由 _markInitialPositionDone 收尾处回放；定位期间的展示值
    // 由 _primeStreamIndexForInitialTarget 预置为目标楼层。
    if (!_controller.isPositioned) {
      _suppressedEyelinePostNumber = postNumber;
      return;
    }
    _suppressedEyelinePostNumber = null;

    // 记录当前浏览位置，用于布局切换时恢复
    _controller.updateViewportPostNumber(postNumber);
    final positionNotifier = ref.read(
      detailScrollPositionProvider((
        topicId: widget.topicId,
        instanceId: _instanceId,
      )).notifier,
    );
    positionNotifier.state = postNumber;

    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final stream = detail.postStream.stream;

    // 迟到上报(16ms 节流/postFrame 跨帧)撞上整流刷新换窗时,postNumber
    // 可能已不在当前窗口;回退 posts.first 会把进度甩到窗口首帖,直接丢弃
    final post = posts.where((p) => p.postNumber == postNumber).firstOrNull;
    if (post == null) return;

    final streamIndex = stream.indexOf(post.id);
    if (streamIndex != -1) {
      final newIndex = streamIndex + 1;
      _controller.updateStreamIndex(newIndex);
    }
  }

  /// 解析初始定位目标（优先级：跳转目标 > 未读分割线 > 视口恢复位置）
  ///
  /// 返回 null 表示无目标（停留在窗口首帖顶部）。
  /// 与旧实现一致：跳转目标与视口位置均缺失时不定位，即使存在分割线。
  /// 初始定位与 [_primeStreamIndexForInitialTarget] 共用本方法，保证
  /// 进度条预置楼层与实际落点永远一致。
  ({int index, bool shouldHighlight})? _resolveInitialTarget(
    List<Post> posts,
    int? dividerPostIndex,
  ) {
    final jumpTarget = _controller.jumpTargetPostNumber;
    final initialPostNumber = _resolvedViewportPostNumber;

    final gate = jumpTarget ?? initialPostNumber;
    if (gate == null || gate == 0) return null;

    if (jumpTarget != null) {
      for (int i = 0; i < posts.length; i++) {
        if (posts[i].postNumber >= jumpTarget) {
          return (
            index: i,
            shouldHighlight: !_controller.skipNextJumpHighlight,
          );
        }
      }
    } else if (dividerPostIndex != null && dividerPostIndex < posts.length) {
      return (index: dividerPostIndex, shouldHighlight: true);
    } else if (initialPostNumber != null && initialPostNumber > 0) {
      for (int i = 0; i < posts.length; i++) {
        if (posts[i].postNumber >= initialPostNumber) {
          return (index: i, shouldHighlight: true);
        }
      }
    }
    return null;
  }

  /// 初始定位前预置进度条楼层
  ///
  /// 目标楼层在数据到达时即可确定，不必等定位完成后由 eyeline 上报，
  /// 否则进度条会先显示低楼层再跳到目标楼层。
  void _primeStreamIndexForInitialTarget(
    TopicDetail detail,
    List<Post> posts,
    int? dividerPostIndex,
  ) {
    final target = _resolveInitialTarget(posts, dividerPostIndex);
    if (target == null) return;
    final targetPost = posts[target.index];
    final targetPostNumber = targetPost.postNumber;

    // 预置视口位置，避免定位期间读取到空值
    _controller.updateViewportPostNumber(targetPostNumber);
    // 本方法在 build 期间调用，provider 写入需推迟到帧后
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final positionNotifier = ref.read(
        detailScrollPositionProvider((
          topicId: widget.topicId,
          instanceId: _instanceId,
        )).notifier,
      );
      positionNotifier.state = targetPostNumber;
    });

    final streamIndex = detail.postStream.stream.indexOf(targetPost.id);
    if (streamIndex != -1) {
      _controller.updateStreamIndex(streamIndex + 1);
    }
  }

  void _updateReadPostNumbers(Set<int> readPostNumbers) {
    if (setEquals(_lastReadPostNumbers, readPostNumbers)) return;
    _lastReadPostNumbers = readPostNumbers;
    _controller.setReadPostNumbers(readPostNumbers);
  }

  void _updateVisiblePosts(Set<int> visiblePostNumbers) {
    _controller.updateVisiblePosts(visiblePostNumbers);
  }

  Future<void> _scrollToTop() async {
    final params = _params;
    final rawDetail = ref.read(topicDetailProvider(params)).value;
    // postIndex 数学必须基于与列表渲染一致的过滤后数据
    final detail = rawDetail == null ? null : _filteredDetail(rawDetail);

    if (detail != null &&
        detail.postStream.posts.isNotEmpty &&
        detail.postStream.posts.first.postNumber == 1) {
      await _controller.scrollToTop();
      return;
    }

    debugPrint('[TopicDetail] First post not loaded, reloading from post 1');
    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = false;

    final notifier = ref.read(topicDetailProvider(params).notifier);
    await notifier.reloadWithPostNumber(1);
  }

  /// J 键：跳到下一帖
  void _scrollToNextPost() {
    unawaited(_navigateByPostOrViewport(1));
  }

  /// K 键：跳到上一帖
  void _scrollToPreviousPost() {
    unawaited(_navigateByPostOrViewport(-1));
  }

  /// 参考 Discourse 网页端：长帖内先翻一屏，翻完后再切到相邻帖子
  Future<void> _navigateByPostOrViewport(int delta) async {
    if (!mounted || delta == 0) return;

    final rawDetail = ref.read(topicDetailProvider(_params)).value;
    if (rawDetail == null) return;
    // 用过滤后列表导航，J/K 自然跳过被屏蔽楼层
    final detail = _filteredDetail(rawDetail);

    final posts = detail.postStream.posts;
    if (posts.isEmpty) return;

    final anchorPostNumber = _resolveNavigationAnchorPostNumber(posts, delta);

    if (_tryScrollWithinCurrentPost(delta, anchorPostNumber)) {
      _controller.updateSelectedPostIndicator(anchorPostNumber);
      return;
    }

    int? targetPostNumber;
    if (delta > 0) {
      targetPostNumber = posts
          .where((post) => post.postNumber > anchorPostNumber)
          .map((post) => post.postNumber)
          .firstOrNull;
      if (targetPostNumber == null && anchorPostNumber < detail.postsCount) {
        targetPostNumber = anchorPostNumber + 1;
      }
    } else {
      targetPostNumber = posts
          .where((post) => post.postNumber < anchorPostNumber)
          .map((post) => post.postNumber)
          .lastOrNull;
      if (targetPostNumber == null && anchorPostNumber > 1) {
        targetPostNumber = anchorPostNumber - 1;
      }
    }

    if (targetPostNumber == null || targetPostNumber == anchorPostNumber) {
      return;
    }
    _controller.updateSelectedPostIndicator(targetPostNumber);
    _selectShortcutPostNumber(detail, targetPostNumber);
    await _jumpToPostInTopic(targetPostNumber);
  }

  int _resolveNavigationAnchorPostNumber(List<Post> posts, int delta) {
    final scrollController = _controller.scrollController;
    final keyboardSelectedPostNumber = _controller.keyboardSelectedPostNumber;
    final viewportPostNumber = _resolvedViewportPostNumber;
    final topVisiblePostNumber = _controller.topVisiblePostNumber;
    final bottomVisiblePostNumber = _controller.bottomVisiblePostNumber;

    if (keyboardSelectedPostNumber != null && keyboardSelectedPostNumber > 0) {
      return keyboardSelectedPostNumber;
    }

    if (viewportPostNumber != null && viewportPostNumber > 0) {
      return viewportPostNumber;
    }

    if (scrollController.hasClients) {
      final position = scrollController.position;
      final isAtTop = (position.pixels - position.minScrollExtent).abs() <= 1.0;
      final isAtBottom =
          (position.maxScrollExtent - position.pixels).abs() <= 1.0;

      if (isAtBottom) {
        return bottomVisiblePostNumber ??
            topVisiblePostNumber ??
            viewportPostNumber ??
            posts.last.postNumber;
      }

      if (isAtTop) {
        return topVisiblePostNumber ??
            bottomVisiblePostNumber ??
            viewportPostNumber ??
            posts.first.postNumber;
      }
    }

    if (delta > 0) {
      return topVisiblePostNumber ??
          bottomVisiblePostNumber ??
          viewportPostNumber ??
          posts.first.postNumber;
    }

    return bottomVisiblePostNumber ??
        topVisiblePostNumber ??
        viewportPostNumber ??
        posts.first.postNumber;
  }

  void _selectShortcutPostNumber(TopicDetail detail, int postNumber) {
    _controller.selectKeyboardPostNumber(postNumber);
    final post = detail.postStream.posts.firstWhere(
      (item) => item.postNumber == postNumber,
      orElse: () => detail.postStream.posts.first,
    );
    final streamIndex = detail.postStream.stream.indexOf(post.id);
    if (streamIndex != -1) {
      _controller.updateStreamIndex(streamIndex + 1);
    }
  }

  bool _tryScrollWithinCurrentPost(int delta, int postNumber) {
    if (!mounted || delta == 0) return false;

    final scrollController = _controller.scrollController;
    if (!scrollController.hasClients) return false;

    final segmentRange = _controller.segmentRangeForPost(postNumber);
    if (segmentRange == null) return false;

    final tagMap = scrollController.tagMap;
    double? renderedTop;
    double? renderedBottom;
    int? minRenderedScrollIndex;
    int? maxRenderedScrollIndex;

    for (final entry in tagMap.entries) {
      if (_controller.postNumberForScrollIndex(entry.key) != postNumber) {
        continue;
      }

      final ctx = entry.value.context;
      if (!ctx.mounted) continue;

      // ctx.mounted=true 不代表 element 仍 active,
      // inactive 状态下 findRenderObject 会抛,跳过即可
      final RenderBox? renderBox;
      try {
        renderBox = ctx.findRenderObject() as RenderBox?;
      } catch (_) {
        continue;
      }
      if (renderBox == null || !renderBox.hasSize || !renderBox.attached) {
        continue;
      }

      final top = renderBox.localToGlobal(Offset.zero).dy;
      final bottom = top + renderBox.size.height;

      renderedTop = renderedTop == null ? top : math.min(renderedTop, top);
      renderedBottom = renderedBottom == null
          ? bottom
          : math.max(renderedBottom, bottom);
      minRenderedScrollIndex = minRenderedScrollIndex == null
          ? entry.key
          : math.min(minRenderedScrollIndex, entry.key);
      maxRenderedScrollIndex = maxRenderedScrollIndex == null
          ? entry.key
          : math.max(maxRenderedScrollIndex, entry.key);
    }

    if (renderedTop == null ||
        renderedBottom == null ||
        minRenderedScrollIndex == null ||
        maxRenderedScrollIndex == null) {
      return false;
    }

    final topBoundary = kToolbarHeight + MediaQuery.of(context).padding.top;
    final viewportHeight = MediaQuery.of(context).size.height;
    final pageDelta = viewportHeight - 3 * topBoundary;
    if (pageDelta <= 0) return false;

    final hasMoreAboveInPost =
        minRenderedScrollIndex > segmentRange.firstScrollIndex ||
        renderedTop < topBoundary - 1;
    final hasMoreBelowInPost =
        maxRenderedScrollIndex < segmentRange.lastScrollIndex ||
        renderedBottom > viewportHeight + 1;

    double? offsetDelta;

    if (delta < 0 && hasMoreAboveInPost) {
      offsetDelta = minRenderedScrollIndex > segmentRange.firstScrollIndex
          ? -pageDelta
          : math.max(-pageDelta, renderedTop - topBoundary);

      if (postNumber == 1 &&
          minRenderedScrollIndex == segmentRange.firstScrollIndex) {
        // 1 楼顶部再往上只放行到列表最顶（露出 header）；
        // 页面滚动限制在当前列表提供的实际范围内。
        offsetDelta = math.max(
          offsetDelta,
          scrollController.position.minScrollExtent - scrollController.offset,
        );
      }
    } else if (delta > 0 && hasMoreBelowInPost) {
      offsetDelta = maxRenderedScrollIndex < segmentRange.lastScrollIndex
          ? pageDelta
          : math.min(pageDelta, renderedBottom - viewportHeight);
    }

    if (offsetDelta == null) return false;

    // 按实际滚动边界截断翻屏距离。
    final targetOffset = (scrollController.offset + offsetDelta).clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    if ((targetOffset - scrollController.offset).abs() < 1) {
      return false;
    }

    scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    return true;
  }

  Future<void> _scrollToPost(int postNumber) async {
    final params = _params;
    final rawDetail = ref.read(topicDetailProvider(params)).value;
    if (rawDetail == null) return;
    _controller.selectKeyboardPostNumber(postNumber);

    // 用过滤后列表确认目标存在；滚动索引按已显示快照的楼层号查找。
    final detail = _filteredDetail(rawDetail);
    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);
    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (postIndex == -1) {
      debugPrint(
        '[TopicDetail] Post $postNumber not in list, reloading with new postNumber',
      );
      _controller.prepareJumpToPost(postNumber);
      _controller.skipNextJumpHighlight = false;

      if (notifier.isSummaryMode ||
          notifier.isAuthorOnlyMode ||
          notifier.isTopLevelMode) {
        await _reloadWithFilterFallback(postNumber: postNumber);
      } else {
        await notifier.reloadWithPostNumber(postNumber);
      }
      return;
    }

    final positionRevision = _controller.positionRevision;
    final positioned = await _controller.scrollToPost(postNumber, posts);
    if (!mounted ||
        _controller.keyboardSelectedPostNumber != postNumber ||
        _controller.positionRevision != positionRevision) {
      return;
    }
    if (!positioned) {
      _controller.jumpToPostLocally(postNumber);
      setState(() {});
    }
    _controller.triggerHighlight(postNumber);
  }

  Future<void> _scrollToPostById(int postId) async {
    final params = _params;
    final rawDetail = ref.read(topicDetailProvider(params)).value;
    if (rawDetail == null) return;
    // 同 _scrollToPost：postIndex 与滚动映射表基于同一份过滤后列表
    final detail = _filteredDetail(rawDetail);

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.id == postId);

    if (postIndex != -1) {
      final post = posts[postIndex];
      _controller.selectKeyboardPostNumber(post.postNumber);

      final positionRevision = _controller.positionRevision;
      final positioned = await _controller.scrollToPost(post.postNumber, posts);
      if (!mounted ||
          _controller.keyboardSelectedPostNumber != post.postNumber ||
          _controller.positionRevision != positionRevision) {
        return;
      }
      if (!positioned) {
        _controller.jumpToPostLocally(post.postNumber);
        setState(() {});
      }
      _controller.triggerHighlight(post.postNumber);
      return;
    }

    debugPrint(
      '[TopicDetail] Post ID $postId not in loaded posts, fetching post info...',
    );

    try {
      final service = DiscourseService();
      final postStream = await service.getPosts(widget.topicId, [postId]);

      if (postStream.posts.isEmpty) {
        debugPrint('[TopicDetail] Failed to fetch post $postId');
        return;
      }

      final targetPost = postStream.posts.first;
      final realPostNumber = targetPost.postNumber;
      debugPrint(
        '[TopicDetail] Got real post_number: $realPostNumber for post ID $postId',
      );

      _controller.prepareJumpToPost(realPostNumber);
      _controller.skipNextJumpHighlight = false;

      final notifier = ref.read(topicDetailProvider(params).notifier);

      if (notifier.isSummaryMode ||
          notifier.isAuthorOnlyMode ||
          notifier.isTopLevelMode) {
        await _reloadWithFilterFallback(
          postNumber: realPostNumber,
          postId: postId,
        );
      } else {
        await notifier.reloadWithPostNumber(realPostNumber);
      }
    } catch (e) {
      debugPrint('[TopicDetail] Error fetching post $postId: $e');
    }
  }

  /// 列表在布局期完成初始定位，帧后揭开内容并恢复阅读上报。
  void _finalizeInitialPosition({
    int? highlightPostNumber,
    int retryCount = 0,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_controller.postListController.isAttached && retryCount < 5) {
        _finalizeInitialPosition(
          highlightPostNumber: highlightPostNumber,
          retryCount: retryCount + 1,
        );
        return;
      }
      _markInitialPositionDone(highlightPostNumber: highlightPostNumber);
    });
  }

  void _markInitialPositionDone({required int? highlightPostNumber}) {
    _controller.clearJumpTarget();
    _controller.skipNextJumpHighlight = false;
    if (highlightPostNumber != null) {
      _controller.pendingHighlightPostNumber = highlightPostNumber;
    }

    // 定位是构造性的，没有滚动事件；落点可能正处于增量加载触发区
    // （如目标帖靠近窗口尾部），主动评估一次，否则要等用户滚动才补载
    _onScroll();

    if (_controller.isPositioned) return;
    _controller.markPositioned();

    if (_controller.pendingHighlightPostNumber != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.consumePendingHighlight();
        }
      });
    }
    // 回放定位期间被抑制的最后一次 eyeline 上报
    // （定位期间的上报被 TopicPostList 去重，不会重发）
    final suppressed = _suppressedEyelinePostNumber;
    if (suppressed != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _suppressedEyelinePostNumber == suppressed) {
          _updateStreamIndexForPostNumber(suppressed);
        }
      });
    }
  }
}
