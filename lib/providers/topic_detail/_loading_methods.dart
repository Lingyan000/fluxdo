part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 加载相关方法
extension LoadingMethods on TopicDetailNotifier {
  /// 加载更早的帖子（向上滚动）
  Future<void> loadPrevious() async {
    if (_isLoadPreviousFailed) return; // 失败后需手动重试
    if (_isFilteredMode) {
      if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
      await _loadPreviousByStreamIds();
      return;
    }
    if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
    _isLoadingPrevious = true;

    try {
      // 不再发射 AsyncLoading.copyWithPrevious:顶部 spinner 由
      // loadingPreviousListenable 驱动,分页起止不触发整页 rebuild。
      final result = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostId = currentPosts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        if (firstIndex <= 0) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostNumber = currentPosts.first.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: firstPostNumber,
          asc: false,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts
            .where((p) => !existingIds.contains(p.id))
            .toList();
        // asc=false 返回的都是当前首帖之前的数据，只需对本页排序后前插。
        // 不再让每次翻页都把已加载的数百楼重新做一次全量排序。
        newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));
        final mergedPosts = [...newPosts, ...currentPosts];

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts
            .map((p) => p.id)
            .where((id) => !existingStreamIds.contains(id))
            .toList();
        final mergedStream = [...newPostIds, ...currentStream];

        final newFirstId = mergedPosts.first.id;
        final newFirstIndex = mergedStream.indexOf(newFirstId);
        _hasMoreBefore = newFirstIndex > 0;

        return currentDetail.copyWith(
          postStream: PostStream(
            posts: mergedPosts,
            stream: mergedStream,
            gaps: currentDetail.postStream.gaps,
          ),
        );
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复;
        // 失败重试按钮由 loadPreviousFailedListenable 驱动
        _isLoadPreviousFailed = true;
      } else {
        state = result;
      }
    } finally {
      _isLoadingPrevious = false;
    }
  }

  /// 手动重试加载更早的帖子
  Future<void> retryLoadPrevious() async {
    _isLoadPreviousFailed = false;
    await loadPrevious();
  }

  /// 加载更多回复（向下滚动）
  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return; // 失败后需手动重试
    if (!_hasMoreAfter ||
        state.isLoading ||
        _isLoadingMore ||
        _isLoadingNewPosts) {
      return;
    }

    if (_isFilteredMode) {
      await _loadMoreByStreamIds();
      return;
    }
    _isLoadingMore = true;

    try {
      // 不再发射 AsyncLoading.copyWithPrevious:底部 spinner 由
      // loadingMoreListenable 驱动,分页起止不触发整页 rebuild。
      final result = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostId = currentPosts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        if (lastIndex == -1 || lastIndex >= stream.length - 1) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostNumber = currentPosts.last.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: lastPostNumber,
          asc: true,
          // 首屏未到末尾时服务端不下发推荐话题,由向下翻页补一次
          includeSuggested: currentDetail.suggestedTopics.isEmpty,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts
            .where((p) => !existingIds.contains(p.id))
            .toList();
        // asc=true 返回的都是当前末帖之后的数据，只排序新增页后追加。
        // 已加载楼层保持原顺序，翻到 300+ 楼时成本不会持续放大。
        newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));
        final mergedPosts = [...currentPosts, ...newPosts];

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts
            .map((p) => p.id)
            .where((id) => !existingStreamIds.contains(id))
            .toList();
        final mergedStream = [...currentStream, ...newPostIds];

        final newLastId = mergedPosts.last.id;
        final newLastIndex = mergedStream.indexOf(newLastId);
        _hasMoreAfter = newLastIndex < mergedStream.length - 1;

        return _withSuggestedCache(currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream, gaps: currentDetail.postStream.gaps),
          suggestedTopics: newPostStream.suggestedTopics.isNotEmpty
              ? newPostStream.suggestedTopics
              : null,
          relatedTopics: newPostStream.relatedTopics.isNotEmpty
              ? newPostStream.relatedTopics
              : null,
        ));
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复
        _isLoadMoreFailed = true;
      } else {
        state = result;
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 手动重试加载更多
  Future<void> retryLoadMore() async {
    _isLoadMoreFailed = false;
    await loadMore();
  }

  /// 收到新回复通知（MessageBus created 消息）
  /// 对齐 Discourse triggerNewPostsInStream：不在底部时只更新 stream，
  /// 在底部时批量加载帖子内容
  void onNewPostCreated(int postId) {
    if (state.isLoading) return;
    if (_isFilteredMode) return;

    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentStream = currentDetail.postStream.stream;
    if (currentStream.contains(postId)) return; // 已在 stream 中
    if (_pendingNewPostIds.contains(postId)) return; // 已在待加载队列

    if (!_hasMoreAfter) {
      // 已加载到底部:对齐网页版 loadedAllPosts 分支 —— 新 id **不先进
      // stream**,只入待加载队列,内容拉到后与 posts 同帧落地(见
      // _loadPendingNewPosts)。若 id 先行入 stream,"最后一帖是否为
      // stream 末尾"的边界判定会出现幽灵窗口:_hasMoreAfter 瞬间翻
      // true,挂在 !hasMoreAfter 下的底部 sliver(推荐区/typing/待审块)
      // 被整段拆掉 → maxScrollExtent 骤减,正在看底部的视口被 clamp 到
      // 最后一帖;内容到达后又装回,闪两次。同帧落地则边界判定全程
      // 自洽,失败时 stream 也不留幽灵 id。
      // postsCount 先行 +1:进度条分母即时反映新回复。
      state = AsyncValue.data(
        currentDetail.copyWith(postsCount: currentDetail.postsCount + 1),
      );
      _pendingNewPostIds.add(postId);
      _loadPendingNewPosts();
    } else {
      // 未到底部:只把 id 记入 stream,内容等用户滚到底由 loadMore 拉
      final newStream = [...currentStream, postId];
      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: currentDetail.postsCount + 1,
        postStream: PostStream(
          posts: currentDetail.postStream.posts,
          stream: newStream,
          gaps: currentDetail.postStream.gaps,
        ),
      ));
      _updateBoundaryState(currentDetail.postStream.posts, newStream);
    }
  }

  /// 批量加载待处理的新帖子（对齐 Discourse triggerNewPostsInStream）
  Future<void> _loadPendingNewPosts() async {
    if (_isLoadingNewPosts) return;
    if (_pendingNewPostIds.isEmpty) return;

    _isLoadingNewPosts = true;
    final postIds = List<int>.from(_pendingNewPostIds);
    _pendingNewPostIds.clear();

    try {
      final service = ref.read(discourseServiceProvider);
      final postStream = await service.getPosts(arg.topicId, postIds);
      final fetchedPosts = postStream.posts;

      if (fetchedPosts.isEmpty || !ref.mounted) return;

      final currentDetail = state.value;
      if (currentDetail == null) return;

      final currentPosts = currentDetail.postStream.posts;
      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = fetchedPosts
          .where((p) => !existingIds.contains(p.id))
          .toList();
      if (newPosts.isEmpty) return;

      // 本地递增被回复帖子的 replyCount（与 Discourse 官方做法一致）
      final replyToNumbers = <int>{};
      for (final p in newPosts) {
        if (p.replyToPostNumber > 0) {
          replyToNumbers.add(p.replyToPostNumber);
        }
      }
      final updatedCurrentPosts = replyToNumbers.isEmpty
          ? currentPosts
          : currentPosts.map((p) {
              if (replyToNumbers.contains(p.postNumber)) {
                return p.copyWith(replyCount: p.replyCount + 1);
              }
              return p;
            }).toList();

      // 只排序新增帖(通常一两条)后追加,不再全量重排已加载的数百楼
      newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));
      final mergedPosts = [...updatedCurrentPosts, ...newPosts];

      // 新帖 id 与内容**同帧**入 stream(onNewPostCreated 底部分支特意
      // 未先入,避免边界判定的幽灵窗口);按楼层号顺序追加
      final mergedStream = [...currentDetail.postStream.stream];
      for (final p in newPosts) {
        if (!mergedStream.contains(p.id)) mergedStream.add(p.id);
      }

      _updateBoundaryState(mergedPosts, mergedStream);

      // 新帖落地会在帖子流末尾长出新内容;用户视口停在其下方(推荐区/
      // 待审块)时属于"锚上方高度变化",武装哨兵做同帧补偿,避免被推跳
      AnchorGuardSliver.arm();

      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(
          posts: mergedPosts,
          stream: mergedStream,
          gaps: currentDetail.postStream.gaps,
        ),
      ));
    } catch (e) {
      // 失败时将 post IDs 放回队列,退避后由 finally 重试(无退避会在
      // 断网时立即重试打转)
      _pendingNewPostIds.insertAll(0, postIds);
      debugPrint('[TopicDetail] 加载新回复失败: $e');
      await Future.delayed(const Duration(seconds: 3));
    } finally {
      _isLoadingNewPosts = false;
      // 如果在加载期间又有新帖子进入队列，继续加载
      if (ref.mounted && _pendingNewPostIds.isNotEmpty) {
        _loadPendingNewPosts();
      }
    }
  }

  /// 使用新的起始帖子号重新加载数据
  Future<void> reloadWithPostNumber(int postNumber) async {
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    await Future.delayed(Duration.zero);

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
        filterTopLevelReplies: _filterTopLevelReplies,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return _withSuggestedCache(detail);
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 刷新当前话题详情（保持列表可见）
  Future<void> refreshWithPostNumber(int postNumber) async {
    if (state.isLoading) return;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: _isFilteredMode ? null : postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return _withSuggestedCache(detail);
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 加载指定楼层的帖子（用于跳转）
  Future<int> loadPostNumber(int postNumber) async {
    final currentDetail = state.value;
    if (currentDetail == null) return -1;

    final currentPosts = currentDetail.postStream.posts;

    final existingIndex = currentPosts.indexWhere(
      (p) => p.postNumber == postNumber,
    );
    if (existingIndex != -1) return existingIndex;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
      );

      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts
          .where((p) => !existingIds.contains(p.id))
          .toList();
      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final currentStream = currentDetail.postStream.stream;
      final newStream = newDetail.postStream.stream;
      final existingStreamIds = currentStream.toSet();
      final newStreamIds = newStream
          .where((id) => !existingStreamIds.contains(id))
          .toList();
      final mergedStream = [...currentStream, ...newStreamIds];

      _updateBoundaryState(mergedPosts, mergedStream);

      if (!ref.mounted) return -1;
      state = AsyncValue.data(
        currentDetail.copyWith(
          postStream: PostStream(
            posts: mergedPosts,
            stream: mergedStream,
            gaps: currentDetail.postStream.gaps,
          ),
        ),
      );

      return mergedPosts.indexWhere((p) => p.postNumber == postNumber);
    } catch (e) {
      debugPrint('[TopicDetail] 加载帖子 #$postNumber 失败: $e');
      return -1;
    }
  }
}
