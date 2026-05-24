part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 用户操作相关方法
extension _UserActions on _TopicDetailPageState {
  Future<void> _handleRefresh() async {
    final params = _params;
    final detailAsync = ref.read(topicDetailProvider(params));
    if (detailAsync.isLoading) return;

    final detail = ref.read(topicDetailProvider(params)).value;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final anchorPostNumber = _controller.getRefreshAnchorPostNumber(
      _resolvedViewportPostNumber ??
          detail?.postStream.posts.firstOrNull?.postNumber,
    );

    setState(() => _isRefreshing = true);
    await notifier.refreshWithPostNumber(anchorPostNumber);

    if (!mounted) return;
    setState(() => _isRefreshing = false);

    final updatedDetail = ref.read(topicDetailProvider(params)).value;
    if (updatedDetail == null) return;

    final isFiltered =
        notifier.isSummaryMode ||
        notifier.isAuthorOnlyMode ||
        notifier.isTopLevelMode;
    final hasAnchor = updatedDetail.postStream.posts.any(
      (p) => p.postNumber == anchorPostNumber,
    );
    if (!isFiltered || hasAnchor) {
      _controller.prepareRefresh(anchorPostNumber, skipHighlight: true);
    } else {
      _controller.clearJumpTarget();
    }
  }

  Future<void> _handleReply(Post? replyToPost, {String? initialContent}) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final detail = ref.read(topicDetailProvider(params)).value;
    final wasAtBottom = !notifier.hasMoreAfter;

    // 预加载草稿：在点击回复时就发起请求，利用 BottomSheet 动画时间并行加载
    final draftKey = Draft.replyKey(
      widget.topicId,
      replyToPostNumber: replyToPost?.postNumber,
    );
    final preloadedDraftFuture = DiscourseService().getDraft(draftKey);

    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: replyToPost,
      initialContent: initialContent,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.replyComposer,
        triggerAction: ShortcutAction.replyTopic,
        repeatActions: ShortcutSurfaceActionSets.replyComposerTriggers,
      ),
    );

    if (newPost != null && mounted) {
      _updateNestedViewAfterReply(newPost);

      final addedToView = ref
          .read(topicDetailProvider(params).notifier)
          .addPost(newPost, wasAtBottom: wasAtBottom);

      if (addedToView) {
        // 回复面板关闭后键盘收起动画约 700ms，期间 viewport 高度持续增大、
        // maxScrollExtent 持续减小。若此时滚动，位置很快会超出 maxScrollExtent，
        // BouncingScrollPhysics 触发弹回，表现为底部弹跳。
        // 等待键盘完全收起（viewInsets.bottom == 0）后再滚动。
        _scrollAfterKeyboardDismiss(newPost.postNumber);
      } else {
        if (mounted) {
          ToastService.show(
            S.current.post_replySent,
            type: ToastType.success,
            actionLabel: S.current.post_replySentAction,
            onAction: () => _scrollToPost(newPost.postNumber),
          );
        }
      }
    }
  }

  /// 等待键盘完全收起后再滚动到指定帖子
  void _scrollAfterKeyboardDismiss(int postNumber) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).viewInsets.bottom > 0) {
        // 键盘仍在收起中，等下一帧再检查
        _scrollAfterKeyboardDismiss(postNumber);
      } else {
        _scrollToPost(postNumber);
      }
    });
  }

  Future<void> _handleEdit(Post post) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    final updatedPost = await showEditSheet(
      context: context,
      topicId: widget.topicId,
      post: post,
      categoryId: detail?.categoryId,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.editComposer,
        triggerAction: ShortcutAction.editPost,
      ),
    );

    if (updatedPost != null && mounted) {
      ref.read(topicDetailProvider(params).notifier).updatePost(updatedPost);
    }
  }

  Future<void> _handleEditTopic() async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final firstPost = detail.postStream.posts
        .where((p) => p.postNumber == 1)
        .firstOrNull;
    final firstPostId = detail.postStream.stream.isNotEmpty
        ? detail.postStream.stream.first
        : null;

    final result = await Navigator.of(context).push<EditTopicResult>(
      MaterialPageRoute(
        builder: (context) => EditTopicPage(
          topicDetail: detail,
          firstPost: firstPost,
          firstPostId: firstPostId,
        ),
      ),
    );

    if (result != null && mounted) {
      ref
          .read(topicDetailProvider(params).notifier)
          .updateTopicInfo(
            title: result.title,
            categoryId: result.categoryId,
            tags: result.tags,
            firstPost: result.updatedFirstPost,
          );
    }
  }

  Future<void> _handleBookmark(
    TopicDetailNotifier notifier, {
    String? traceId,
    String source = 'topic_detail_topic',
  }) async {
    final resolvedTraceId = traceId ?? createBookmarkEditTraceId();
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null) {
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'detail_missing',
        traceId: resolvedTraceId,
        source: source,
        message: '编辑书签时未拿到话题详情',
        topicId: widget.topicId,
      );
      return;
    }

    writeBookmarkEditTrace(
      phase: 'handle_bookmark_enter',
      traceId: resolvedTraceId,
      source: source,
      message: '进入详情页编辑书签处理逻辑',
      topicId: widget.topicId,
      bookmarkId: detail.bookmarkId ?? _fallbackBookmarkId,
      bookmarkName: detail.bookmarkName ?? _fallbackBookmarkName,
      bookmarked: detail.bookmarked,
      hasReminder: detail.bookmarkReminderAt != null,
    );

    final editTarget = _bookmarkEditTarget(detail);
    if (editTarget != null) {
      writeBookmarkEditTrace(
        phase: 'launcher_request',
        traceId: resolvedTraceId,
        source: source,
        message: '详情页准备打开编辑书签面板',
        topicId: widget.topicId,
        postId: editTarget.postId,
        bookmarkId: editTarget.bookmarkId,
        bookmarkName: editTarget.initialName,
        initialName: editTarget.initialName,
        hasReminder: editTarget.initialReminderAt != null,
      );

      final result = await showBookmarkEditSheetWithCachedNames(
        context,
        ref,
        bookmarkId: editTarget.bookmarkId,
        initialName: editTarget.initialName,
        initialReminderAt: editTarget.initialReminderAt,
        traceId: resolvedTraceId,
        source: source,
        topicId: widget.topicId,
        postId: editTarget.postId,
      );
      if (result == null || !mounted) return;

      if (editTarget.source == TopicBookmarkTargetSource.routeFallback) {
        // 用户在本页改/删了 fallback，标记后续 didUpdateWidget 不再用父级
        // 旧 initialBookmark* 覆盖回来。
        _userMutatedFallback = true;
        if (result.deleted) {
          _fallbackBookmarkId = null;
          _fallbackBookmarkName = null;
          _fallbackBookmarkReminderAt = null;
          _fallbackBookmarkableType = null;
        } else {
          _fallbackBookmarkId = editTarget.bookmarkId;
          _fallbackBookmarkName = result.name;
          _fallbackBookmarkReminderAt = result.reminderAt;
          _fallbackBookmarkableType = editTarget.bookmarkableType;
        }
      }

      if (editTarget.isTopicBookmark) {
        if (result.deleted) {
          // BookmarkEditSheet 已调用 API 删除，刷新元数据同步本地状态
          notifier.reloadTopicMetadata();
        } else {
          notifier.updateTopicBookmarkMeta(
            name: result.name,
            reminderAt: result.reminderAt,
          );
        }
        return;
      }

      final targetPost = editTarget.postId == null
          ? null
          : detail.postStream.posts
                .where((post) => post.id == editTarget.postId)
                .firstOrNull;
      if (result.deleted) {
        // 帖子级书签：优先按 postId 拉取该帖最新状态，避免 reloadTopicMetadata
        // 只刷话题级元数据导致本地 post.bookmarked 与服务端不一致。
        if (editTarget.postId != null) {
          notifier.refreshPost(editTarget.postId!, preserveCooked: true);
        } else {
          notifier.reloadTopicMetadata();
        }
      } else if (targetPost != null) {
        notifier.updatePost(
          targetPost.copyWith(
            bookmarked: true,
            bookmarkId: editTarget.bookmarkId,
            bookmarkName: result.name,
            bookmarkReminderAt: result.reminderAt,
          ),
        );
      } else if (editTarget.postId != null) {
        // 帖子还未加载到详情页（如长楼跨度跳转）但服务端已写入新数据，
        // 拉取最新 post 状态，保证后续滚动到该楼时显示正确。
        notifier.refreshPost(editTarget.postId!, preserveCooked: true);
      }
      return;
    }

    if (detail.bookmarked) {
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'bookmark_id_missing',
        traceId: resolvedTraceId,
        source: source,
        message: '话题已书签但未解析到可编辑的书签目标',
        topicId: widget.topicId,
        bookmarkName: detail.bookmarkName,
        initialName: _fallbackBookmarkName,
        bookmarked: detail.bookmarked,
        hasReminder: detail.bookmarkReminderAt != null,
      );
      return;
    }

    // 未书签 → 创建书签，然后弹出编辑 BottomSheet
    try {
      final newBookmarkId = await notifier.addTopicBookmark();
      if (!mounted) return;
      ToastService.showSuccess(S.current.common_bookmarkAdded);
      writeBookmarkEditTrace(
        phase: 'bookmark_created',
        traceId: resolvedTraceId,
        source: source,
        message: '详情页已新建书签，准备打开编辑面板',
        topicId: widget.topicId,
        bookmarkId: newBookmarkId,
        bookmarked: true,
      );

      // 弹出编辑 BottomSheet
      final result = await showBookmarkEditSheetWithCachedNames(
        context,
        ref,
        bookmarkId: newBookmarkId,
        traceId: resolvedTraceId,
        source: source,
        topicId: widget.topicId,
      );
      if (result == null || !mounted) return;

      if (result.deleted) {
        // BookmarkEditSheet 已调用 API 删除，刷新元数据同步本地状态
        notifier.reloadTopicMetadata();
      } else {
        notifier.updateTopicBookmarkMeta(
          name: result.name,
          reminderAt: result.reminderAt,
        );
      }
    } on DioException catch (e) {
      // 网络错误的 toast 已由 ErrorInterceptor 对 POST/PUT/DELETE 默认弹出，
      // 这里只补记 trace 方便事后排障与其它分支保持一致。
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'bookmark_create_dio_error',
        traceId: resolvedTraceId,
        source: source,
        message: '详情页新建书签失败',
        topicId: widget.topicId,
        error: e,
      );
    } catch (e, s) {
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'bookmark_create_throw',
        traceId: resolvedTraceId,
        source: source,
        message: '详情页新建书签抛出异常',
        topicId: widget.topicId,
        error: e,
        stackTrace: s,
      );
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _handleReadLater() {
    final notifier = ref.read(readLaterProvider.notifier);
    final detail = ref.read(topicDetailProvider(_params)).value;

    if (notifier.contains(widget.topicId)) {
      // 已在列表中 → 移除
      notifier.remove(widget.topicId);
      ToastService.showSuccess(
        S.current.topicDetail_removeFromReadLaterSuccess,
      );
    } else {
      // 不在列表中 → 添加
      final item = ReadLaterItem(
        topicId: widget.topicId,
        title: detail?.title ?? widget.initialTitle ?? '',
        scrollToPostNumber: _resolvedViewportPostNumber,
        addedAt: DateTime.now(),
      );
      final success = notifier.add(item);
      if (success) {
        ToastService.showSuccess(S.current.topicDetail_addToReadLaterSuccess);
      } else {
        ToastService.showError(
          S.current.topicDetail_readLaterFull(maxReadLaterItems),
        );
      }
    }
  }

  void _handleVoteChanged(int newVoteCount, bool userVoted) {
    final params = _params;
    ref
        .read(topicDetailProvider(params).notifier)
        .updateTopicVote(newVoteCount, userVoted);
  }

  void _handleSolutionChanged(int postId, bool accepted) {
    final params = _params;
    ref
        .read(topicDetailProvider(params).notifier)
        .updatePostSolution(postId, accepted);
  }

  void _handleRefreshPost(int postId) {
    final params = _params;
    ref.read(topicDetailProvider(params).notifier).refreshPost(postId);
  }

  void _handleNotificationLevelChanged(
    TopicDetailNotifier notifier,
    TopicNotificationLevel level,
  ) async {
    try {
      await notifier.updateNotificationLevel(level);
      if (mounted) {
        ToastService.showSuccess(S.current.topicDetail_setToLevel(level.label));
      }
    } on DioException catch (e) {
      // 网络错误已由 ErrorInterceptor 处理
      debugPrint('[TopicDetail] 更新订阅级别失败: $e');
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _shareTopic() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  Future<void> _openInBrowser() async {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );

    final success = await launchInExternalBrowser(url);
    if (!success && mounted) {
      ToastService.showError(S.current.topicDetail_cannotOpenBrowser);
    }
  }

  void _shareAsImage() {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    // 尝试获取已加载的主帖，如果没有则传 null，ShareImagePreview 会自动获取
    final firstPost = detail.postStream.posts
        .where((p) => p.postNumber == 1)
        .firstOrNull;
    ShareImagePreview.show(context, detail, post: firstPost);
  }

  void _sharePostAsImage(Post post) {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    ShareImagePreview.show(context, detail, post: post);
  }

  Post? _currentShortcutPost() {
    final detail = ref.read(topicDetailProvider(_params)).value;
    final posts = detail?.postStream.posts;
    if (posts == null || posts.isEmpty) return null;

    final currentPostNumber = _resolvedShortcutPostNumber;
    if (currentPostNumber == null) return posts.first;

    Post? nearestPost;
    int? nearestDistance;
    for (final post in posts) {
      final distance = (post.postNumber - currentPostNumber).abs();
      if (nearestDistance == null || distance < nearestDistance) {
        nearestPost = post;
        nearestDistance = distance;
      }
    }

    return nearestPost ?? posts.first;
  }

  Post? _currentReplyTargetPost() {
    final post = _currentShortcutPost();
    if (post == null || post.postNumber == 1) return null;
    return post;
  }

  Future<void> _handleQuotePost(Post post) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final detail = ref.read(topicDetailProvider(params)).value;
    final wasAtBottom = !notifier.hasMoreAfter;

    String markdown = '';
    final raw = await DiscourseService().getPostRaw(post.id);
    if (raw != null && raw.trim().isNotEmpty) {
      markdown = raw.trim();
    } else {
      markdown = HtmlToMarkdown.convert(post.cooked).trim();
    }

    if (markdown.isEmpty) return;
    if (!mounted) return;

    final quote = QuoteBuilder.build(
      markdown: markdown,
      username: post.username,
      postNumber: post.postNumber,
      topicId: widget.topicId,
    );

    final draftKey = Draft.replyKey(
      widget.topicId,
      replyToPostNumber: post.postNumber,
    );
    final preloadedDraftFuture = DiscourseService().getDraft(draftKey);

    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: post,
      initialContent: quote,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.replyComposer,
        triggerAction: ShortcutAction.quotePost,
        repeatActions: ShortcutSurfaceActionSets.replyComposerTriggers,
      ),
    );

    if (newPost != null && mounted) {
      _updateNestedViewAfterReply(newPost);

      final addedToView = ref
          .read(topicDetailProvider(params).notifier)
          .addPost(newPost, wasAtBottom: wasAtBottom);

      if (addedToView) {
        _scrollAfterKeyboardDismiss(newPost.postNumber);
      } else {
        ToastService.show(
          S.current.post_replySent,
          type: ToastType.success,
          actionLabel: S.current.post_replySentAction,
          onAction: () => _scrollToPost(newPost.postNumber),
        );
      }
    }
  }

  Future<void> _togglePostLike(Post post) async {
    try {
      final result = await DiscourseService().toggleReaction(
        post.id,
        post.currentUserReaction?.id ?? 'heart',
      );
      if (!mounted) return;

      ref
          .read(topicDetailProvider(_params).notifier)
          .updatePostReaction(
            post.id,
            result['reactions'] as List<PostReaction>,
            result['currentUserReaction'] as PostReaction?,
          );
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _handlePostBookmark(Post post) async {
    final notifier = ref.read(topicDetailProvider(_params).notifier);
    final traceId = createBookmarkEditTraceId();

    if (post.bookmarked && post.bookmarkId != null) {
      writeBookmarkEditTrace(
        phase: 'post_bookmark_edit_request',
        traceId: traceId,
        source: 'topic_detail_post_action',
        message: '帖子级书签准备打开编辑面板',
        topicId: widget.topicId,
        postId: post.id,
        bookmarkId: post.bookmarkId,
        bookmarkName: post.bookmarkName,
        initialName: post.bookmarkName,
        bookmarked: post.bookmarked,
        hasReminder: post.bookmarkReminderAt != null,
      );
      final result = await showBookmarkEditSheetWithCachedNames(
        context,
        ref,
        bookmarkId: post.bookmarkId!,
        initialName: post.bookmarkName,
        initialReminderAt: post.bookmarkReminderAt,
        traceId: traceId,
        source: 'topic_detail_post_action',
        topicId: widget.topicId,
        postId: post.id,
      );
      if (result == null || !mounted) return;

      if (result.deleted) {
        notifier.refreshPost(post.id, preserveCooked: true);
      } else {
        notifier.updatePost(
          post.copyWith(
            bookmarked: true,
            bookmarkId: post.bookmarkId,
            bookmarkName: result.name,
            bookmarkReminderAt: result.reminderAt,
          ),
        );
      }
      return;
    }

    try {
      final bookmarkId = await DiscourseService().bookmarkPost(post.id);
      if (!mounted) return;

      notifier.updatePost(
        post.copyWith(
          bookmarked: true,
          bookmarkId: bookmarkId,
          bookmarkName: null,
          bookmarkReminderAt: null,
        ),
      );
      ToastService.showSuccess(S.current.common_bookmarkAdded);
      writeBookmarkEditTrace(
        phase: 'post_bookmark_created',
        traceId: traceId,
        source: 'topic_detail_post_action',
        message: '帖子级书签已创建，准备打开编辑面板',
        topicId: widget.topicId,
        postId: post.id,
        bookmarkId: bookmarkId,
        bookmarked: true,
      );

      final result = await showBookmarkEditSheetWithCachedNames(
        context,
        ref,
        bookmarkId: bookmarkId,
        traceId: traceId,
        source: 'topic_detail_post_action',
        topicId: widget.topicId,
        postId: post.id,
      );
      if (result == null || !mounted) return;

      if (result.deleted) {
        notifier.refreshPost(post.id, preserveCooked: true);
      } else {
        notifier.updatePost(
          post.copyWith(
            bookmarked: true,
            bookmarkId: bookmarkId,
            bookmarkName: result.name,
            bookmarkReminderAt: result.reminderAt,
          ),
        );
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _sharePost(Post post) {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}/${post.postNumber}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  void _showFlagPostSheet(Post post) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.postFlag,
        triggerAction: ShortcutAction.flagPost,
      ),
      builder: (context) => PostFlagSheet(
        postId: post.id,
        postUsername: post.username,
        service: DiscourseService(),
        onSuccess: () => ToastService.showSuccess(S.current.post_flagSubmitted),
      ),
    );
  }

  Future<void> _handleDeletePost(Post post) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.postDeleteConfirm,
        triggerAction: ShortcutAction.deletePost,
      ),
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.post_deleteReplyTitle),
        content: Text(context.l10n.post_deleteReplyConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DiscourseService().deletePost(post.id);
      if (!mounted) return;

      ref.read(topicDetailProvider(_params).notifier).markPostDeleted(post.id);
      ToastService.showSuccess(context.l10n.common_deleted);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _showJumpToPostDialog() {
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null) return;

    final controller = TextEditingController(
      text: _resolvedShortcutPostNumber?.toString() ?? '',
    );

    showAppDialog(
      context: context,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.topicJumpToPost,
        triggerAction: ShortcutAction.jumpToPost,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
      ),
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topic_jump),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: context.l10n.topic_currentFloor,
            hintText: '1 - ${detail.postsCount}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              final postNumber = int.tryParse(controller.text.trim());
              Navigator.pop(context);
              if (postNumber != null && postNumber > 0) {
                _scrollToPost(postNumber.clamp(1, detail.postsCount));
              }
            },
            child: Text(context.l10n.topic_jump),
          ),
        ],
      ),
    );
  }

  Future<void> _jumpToUnreadPost() async {
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null || detail.postsCount <= 0) return;

    var maxReadPostNumber = detail.lastReadPostNumber ?? 0;
    for (final postNumber in _lastReadPostNumbers) {
      if (postNumber > maxReadPostNumber) {
        maxReadPostNumber = postNumber;
      }
    }

    final targetLoadedPost = detail.postStream.posts
        .where((post) => post.postNumber > maxReadPostNumber)
        .firstOrNull;
    final targetPostNumber =
        targetLoadedPost?.postNumber ??
        (maxReadPostNumber < detail.postsCount ? maxReadPostNumber + 1 : null);

    if (targetPostNumber != null) {
      await _scrollToPost(targetPostNumber);
    }
  }

  void _showExportSheet() {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    ExportSheet.show(context, detail);
  }

  /// 处理划词引用
  Future<void> _handleQuoteSelection(String selectedText, Post post) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final detail = ref.read(topicDetailProvider(params)).value;
    final wasAtBottom = !notifier.hasMoreAfter;
    final codePayload = CodeSelectionContextTracker.instance.decodePayload(
      selectedText,
    );
    final plainSelectedText = codePayload?.text ?? selectedText;

    // 尝试从 HTML 提取对应片段并转为 Markdown
    String markdown;
    final htmlFragment = HtmlTextMapper.extractHtml(
      post.cooked,
      plainSelectedText,
    );
    if (htmlFragment != null) {
      markdown = HtmlToMarkdown.convert(htmlFragment);
      // 转换失败时降级为纯文本
      if (markdown.trim().isEmpty) {
        markdown = codePayload != null
            ? CodeSelectionContextTracker.instance.toMarkdown(
                plainSelectedText,
                context: codePayload.context,
              )
            : plainSelectedText;
      }
    } else if (codePayload != null) {
      markdown = CodeSelectionContextTracker.instance.toMarkdown(
        plainSelectedText,
        context: codePayload.context,
      );
    } else {
      // 映射失败，使用纯文本
      markdown = plainSelectedText;
    }

    // 构建引用格式
    final quote = QuoteBuilder.build(
      markdown: markdown,
      username: post.username,
      postNumber: post.postNumber,
      topicId: widget.topicId,
    );

    // 预加载草稿
    final draftKey = Draft.replyKey(
      widget.topicId,
      replyToPostNumber: post.postNumber,
    );
    final preloadedDraftFuture = DiscourseService().getDraft(draftKey);

    // 打开回复框，预填引用内容（回复给被引用的帖子）
    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: post,
      initialContent: quote,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.replyComposer,
        triggerAction: ShortcutAction.quotePost,
        repeatActions: ShortcutSurfaceActionSets.replyComposerTriggers,
      ),
    );

    if (newPost != null && mounted) {
      _updateNestedViewAfterReply(newPost);

      final addedToView = ref
          .read(topicDetailProvider(params).notifier)
          .addPost(newPost, wasAtBottom: wasAtBottom);
      if (addedToView) {
        _scrollAfterKeyboardDismiss(newPost.postNumber);
      } else {
        if (mounted) {
          ToastService.show(
            S.current.post_replySent,
            type: ToastType.success,
            actionLabel: S.current.post_replySentAction,
            onAction: () => _scrollToPost(newPost.postNumber),
          );
        }
      }
    }
  }

  /// 处理图片引用（quote 已在 ImageContextMenu 中构建好）
  Future<void> _handleImageQuote(String quote, Post post) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final detail = ref.read(topicDetailProvider(params)).value;
    final wasAtBottom = !notifier.hasMoreAfter;

    // 预加载草稿
    final draftKey = Draft.replyKey(
      widget.topicId,
      replyToPostNumber: post.postNumber,
    );
    final preloadedDraftFuture = DiscourseService().getDraft(draftKey);

    // 打开回复框，预填引用内容
    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: post,
      initialContent: quote,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.replyComposer,
        triggerAction: ShortcutAction.quotePost,
        repeatActions: ShortcutSurfaceActionSets.replyComposerTriggers,
      ),
    );

    if (newPost != null && mounted) {
      _updateNestedViewAfterReply(newPost);

      final addedToView = ref
          .read(topicDetailProvider(params).notifier)
          .addPost(newPost, wasAtBottom: wasAtBottom);
      if (addedToView) {
        _scrollAfterKeyboardDismiss(newPost.postNumber);
      } else {
        if (mounted) {
          ToastService.show(
            S.current.post_replySent,
            type: ToastType.success,
            actionLabel: S.current.post_replySentAction,
            onAction: () => _scrollToPost(newPost.postNumber),
          );
        }
      }
    }
  }

  /// 回复成功后更新嵌套视图
  void _updateNestedViewAfterReply(Post newPost) {
    if (!_isNestedView) return;
    final nestedParams = NestedTopicParams(topicId: widget.topicId);
    ref.read(nestedTopicProvider(nestedParams).notifier).addNewPost(newPost, isOwnPost: true);
  }

  /// MessageBus created 事件：获取完整帖子数据并更新嵌套视图
  Future<void> _handleNestedCreated(int postId, int? userId) async {
    final nestedParams = NestedTopicParams(topicId: widget.topicId);
    final nestedNotifier = ref.read(nestedTopicProvider(nestedParams).notifier);

    // 去重：如果已存在（自己回复时 _updateNestedViewAfterReply 可能已处理）
    final current = ref.read(nestedTopicProvider(nestedParams)).value;
    if (current == null) return;
    if (current.roots.any((n) => n.post.id == postId)) return;

    try {
      final post = await DiscourseService().getPost(postId);
      if (!mounted) return;

      final currentUser = ref.read(currentUserProvider).value;
      final isOwnPost = userId != null && userId == currentUser?.id;
      nestedNotifier.addNewPost(post, isOwnPost: isOwnPost);
    } catch (e) {
      debugPrint('[TopicDetail] _handleNestedCreated 失败: $e');
    }
  }

  /// 处理帖子级别的 MessageBus 更新
  void _handlePostUpdate(TopicDetailNotifier notifier, PostUpdate update) {
    switch (update.type) {
      case TopicMessageType.created:
        notifier.onNewPostCreated(update.postId);
        if (_isNestedView) {
          _handleNestedCreated(update.postId, update.userId);
        }
        break;
      case TopicMessageType.revised:
      case TopicMessageType.rebaked:
        notifier.refreshPost(update.postId, updatedAt: update.updatedAt);
        break;
      case TopicMessageType.acted:
        // 对齐 Discourse 官方 triggerChangedPost：acted 也传 updatedAt 做去重
        notifier.refreshPost(
          update.postId,
          preserveCooked: true,
          updatedAt: update.updatedAt,
        );
        break;
      case TopicMessageType.deleted:
        notifier.markPostDeleted(update.postId);
        break;
      case TopicMessageType.destroyed:
        notifier.removePost(update.postId);
        break;
      case TopicMessageType.recovered:
        notifier.markPostRecovered(update.postId);
        break;
      case TopicMessageType.liked:
      case TopicMessageType.unliked:
        notifier.updatePostLikes(update.postId, likesCount: update.likesCount);
        break;
      case TopicMessageType.boostAdded:
        if (update.boostData != null) {
          notifier.addBoostToPost(update.postId, update.boostData!);
        }
        break;
      case TopicMessageType.boostRemoved:
        if (update.boostId != null) {
          notifier.removeBoostFromPost(update.postId, update.boostId!);
        }
        break;
      case TopicMessageType.policyChanged:
        // policy 接受/撤销不改 post 内容，用 preserveCooked 避免重新跑 cook。
        // 不传 updatedAt：policy_change 服务端不会更新 post.updated_at。
        notifier.refreshPost(update.postId, preserveCooked: true);
        break;
      default:
        break;
    }
  }

  /// 处理 reload_topic 消息
  void _handleReloadTopic(TopicDetailNotifier notifier, bool refreshStream) {
    final anchor = _controller.getRefreshAnchorPostNumber(
      _resolvedViewportPostNumber,
    );
    if (refreshStream) {
      notifier.refreshWithPostNumber(anchor);
    } else {
      notifier.reloadTopicMetadata();
    }
  }

  /// 切换嵌套视图
  void _toggleNestedView() {
    setState(() => _isNestedView = !_isNestedView);
    _scheduleCheckTitleVisibility();
  }
}
