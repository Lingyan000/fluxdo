part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 滚动和导航相关方法
extension _ScrollActions on _TopicDetailPageState {
  void _onScroll() {
    if (_isRefreshing) return;

    _scheduleCheckTitleVisibility();
    _controller.handleScroll();

    final params = _params;
    final detailAsync = ref.read(topicDetailProvider(params));

    if (detailAsync.isLoading) return;

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
    // 记录当前浏览位置，用于布局切换时恢复
    _controller.updateViewportPostNumber(postNumber);
    ref.read(detailScrollPositionProvider(widget.topicId).notifier).state =
        postNumber;

    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final stream = detail.postStream.stream;

    final post = posts.firstWhere(
      (p) => p.postNumber == postNumber,
      orElse: () => posts.first,
    );

    final streamIndex = stream.indexOf(post.id);
    if (streamIndex != -1) {
      final newIndex = streamIndex + 1;
      _controller.updateStreamIndex(newIndex);
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
    final detail = ref.read(topicDetailProvider(params)).value;

    if (detail != null &&
        detail.postStream.posts.isNotEmpty &&
        detail.postStream.posts.first.postNumber == 1) {
      _controller.scrollToTop();
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

    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null) return;

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
    await _scrollToPost(targetPostNumber);
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
        offsetDelta = math.max(offsetDelta, -scrollController.offset);
      }
    } else if (delta > 0 && hasMoreBelowInPost) {
      offsetDelta = maxRenderedScrollIndex < segmentRange.lastScrollIndex
          ? pageDelta
          : math.min(pageDelta, renderedBottom - viewportHeight);
    }

    if (offsetDelta == null) return false;

    final targetOffset = (scrollController.offset + offsetDelta).clamp(
      0.0,
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
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;
    _controller.selectKeyboardPostNumber(postNumber);

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

    // 计算距离，如果距离过大直接使用本地跳转
    bool forceLocalJump = false;
    final stream = detail.postStream.stream;
    final currentVisibleIndex = _controller.currentVisibleStreamIndex;

    final targetPost = posts.firstWhere(
      (p) => p.postNumber == postNumber,
      orElse: () => posts.first,
    );
    final targetStreamIndex = stream.indexOf(targetPost.id);

    if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
      if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
        forceLocalJump = true;
      }
    }

    if (!forceLocalJump && _controller.isPostRendered(postIndex)) {
      await _controller.scrollToPost(postNumber, posts);
    } else {
      int? anchorPostNumber;
      if (posts.length - 1 - postIndex < 20) {
        final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
        anchorPostNumber = posts[safeIndex].postNumber;
      }
      _controller.jumpToPostLocally(
        postNumber,
        anchorPostNumber: anchorPostNumber,
      );
      if (mounted) setState(() {});
    }
    _controller.triggerHighlight(postNumber);
  }

  /// 进度条水平 scrub：按真实楼层号跳转（拖动中尽量轻量，避免狂刷 rebuild）
  Future<void> _scrubToPostNumber(
    int postNumber, {
    bool finalize = false,
  }) async {
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null) return;

    final maxPost = detail.postsCount > 0
        ? detail.postsCount
        : detail.postStream.stream.length;
    final target = postNumber.clamp(1, maxPost < 1 ? 1 : maxPost);

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.postNumber == target);

    if (postIndex != -1) {
      final post = posts[postIndex];
      _controller.updateViewportPostNumber(post.postNumber);

      final streamIndex = detail.postStream.stream.indexOf(post.id);
      if (streamIndex != -1) {
        _controller.updateStreamIndex(streamIndex + 1);
      }

      // 已渲染：直接 scrollToIndex（1ms），不重置列表状态
      if (_controller.isPostRendered(postIndex)) {
        await _controller.scrollToPost(post.postNumber, posts);
        return;
      }

      // 已加载未渲染：本地瞬跳，不 setState、不高亮
      int? anchorPostNumber;
      if (posts.length - 1 - postIndex < 20) {
        final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
        anchorPostNumber = posts[safeIndex].postNumber;
      }
      _controller.jumpToPostLocally(
        post.postNumber,
        anchorPostNumber: anchorPostNumber,
      );
      return;
    }

    // 目标楼未加载：拖动中先落到最近已加载楼，避免每次 reload
    if (!finalize && posts.isNotEmpty) {
      Post nearest = posts.first;
      var best = (posts.first.postNumber - target).abs();
      for (final p in posts) {
        final d = (p.postNumber - target).abs();
        if (d < best) {
          best = d;
          nearest = p;
        }
      }
      if (nearest.postNumber != target) {
        await _scrubToPostNumber(nearest.postNumber, finalize: false);
      }
      return;
    }

    // 松手时再做完整跳转（可能 reload）
    await _scrollToPost(target);
  }

  /// stream 1-based 索引 → 真实 post_number（隐藏楼时二者不等）
  int _resolvePostNumberFromStreamIndex(
    TopicDetail detail,
    int streamIndex1Based,
  ) {
    final stream = detail.postStream.stream;
    if (stream.isEmpty) return 1;
    final index = streamIndex1Based.clamp(1, stream.length) - 1;
    final postId = stream[index];
    final posts = detail.postStream.posts;
    final loaded = posts.where((p) => p.id == postId).firstOrNull;
    if (loaded != null) return loaded.postNumber;
    return streamIndex1Based;
  }

  Future<void> _scrollToPostById(int postId) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.id == postId);

    if (postIndex != -1) {
      final post = posts[postIndex];
      _controller.selectKeyboardPostNumber(post.postNumber);

      bool forceLocalJump = false;
      final currentVisibleIndex = _controller.currentVisibleStreamIndex;
      final targetStreamIndex = detail.postStream.stream.indexOf(postId);

      if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
        if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
          forceLocalJump = true;
        }
      }

      if (!forceLocalJump && _controller.isPostRendered(postIndex)) {
        await _controller.scrollController.scrollToIndex(
          _controller.scrollIndexForPostIndex(postIndex),
          preferPosition: AutoScrollPosition.begin,
          duration: const Duration(milliseconds: 1),
        );
      } else {
        int? anchorPostNumber;
        if (posts.length - 1 - postIndex < 20) {
          final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
          anchorPostNumber = posts[safeIndex].postNumber;
        }

        _controller.jumpToPostLocally(
          post.postNumber,
          anchorPostNumber: anchorPostNumber,
        );
        if (mounted) setState(() {});
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

  void _scrollToInitialPosition(List<Post> posts, int? dividerPostIndex) {
    _doInitialScroll(posts, dividerPostIndex, retryCount: 0);
  }

  void _doInitialScroll(
    List<Post> posts,
    int? dividerPostIndex, {
    required int retryCount,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      if (retryCount == 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      if (!mounted) return;

      if (!_controller.scrollController.hasClients) {
        if (retryCount < 5) {
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            _doInitialScroll(
              posts,
              dividerPostIndex,
              retryCount: retryCount + 1,
            );
          }
          return;
        } else {
          if (mounted && !_controller.isPositioned) {
            _controller.markPositioned();
          }
          return;
        }
      }

      try {
        int? targetPostIndex;
        bool shouldHighlight = false;
        final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
        final jumpTarget = _controller.jumpTargetPostNumber;
        final initialPostNumber = _resolvedViewportPostNumber;

        if (jumpTarget != null) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= jumpTarget) {
              targetPostIndex = i;
              shouldHighlight = !_controller.skipNextJumpHighlight;
              break;
            }
          }
        } else if (dividerPostIndex != null &&
            dividerPostIndex < posts.length) {
          targetPostIndex = dividerPostIndex;
          shouldHighlight = true;
        } else if (initialPostNumber != null && initialPostNumber > 0) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= initialPostNumber) {
              targetPostIndex = i;
              shouldHighlight = true;
              break;
            }
          }
        }

        if (targetPostIndex != null) {
          if (hasFirstPost && targetPostIndex == 0) {
            await _controller.scrollController.animateTo(
              _controller.scrollController.position.minScrollExtent,
              duration: const Duration(milliseconds: 1),
              curve: Curves.linear,
            );
          } else {
            await _controller.scrollController.scrollToIndex(
              _controller.scrollIndexForPostIndex(targetPostIndex),
              preferPosition: AutoScrollPosition.begin,
              duration: const Duration(milliseconds: 1),
            );
          }

          _controller.clearJumpTarget();
          _controller.skipNextJumpHighlight = false;

          if (shouldHighlight) {
            _controller.pendingHighlightPostNumber =
                posts[targetPostIndex].postNumber;
          }
        }
      } catch (e, stack) {
        debugPrint('[TopicDetail] Scroll error: $e\n$stack');
      } finally {
        if (mounted && !_controller.isPositioned) {
          _controller.markPositioned();
          if (_controller.pendingHighlightPostNumber != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _controller.consumePendingHighlight();
              }
            });
          }
        }
      }
    });
  }
}
