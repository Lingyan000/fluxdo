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
      topicTitle: detail?.title,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      isPmWithNonHumanUser: detail?.pmWithNonHumanUser ?? false,
      // 回复被送审:即时挂进帖子流底部的待审块(官方同款行为)
      onEnqueued: (pending) => ref
          .read(topicDetailProvider(params).notifier)
          .addPendingPost(pending),
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

  /// 撤回待审核回复(带确认弹窗)。返回是否真正撤回成功。
  Future<bool> _withdrawPendingPost(
    PendingPost pending, {
    required String confirmTitle,
    required String confirmContent,
    required String confirmLabel,
  }) async {
    final params = _params;
    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: Text(confirmTitle),
            content: Text(confirmContent),
            actions: [
              TextButton(
                onPressed: isDeleting
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: Text(dialogContext.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: isDeleting
                    ? null
                    : () async {
                        setState(() => isDeleting = true);
                        try {
                          await DiscourseService()
                              .deleteReviewable(pending.id);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            setState(() => isDeleting = false);
                            ToastService.showError(
                              S.current.review_withdrawFailed(e.toString()),
                            );
                          }
                        }
                      },
                child: isDeleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(confirmLabel),
              ),
            ],
          ),
        );
      },
    );

    if (confirmed != true || !mounted) return false;
    ref
        .read(topicDetailProvider(params).notifier)
        .removePendingPost(pending.id);
    return true;
  }

  Future<void> _handleWithdrawPending(PendingPost pending) async {
    final withdrawn = await _withdrawPendingPost(
      pending,
      confirmTitle: S.current.review_withdrawConfirmTitle,
      confirmContent: S.current.review_withdrawConfirmContent,
      confirmLabel: S.current.review_withdraw,
    );
    if (withdrawn && mounted) {
      PendingReplyTargetRegistry.remove(pending.id);
      ToastService.showSuccess(S.current.review_withdrawn);
    }
  }

  Future<void> _handleWithdrawAndEditPending(PendingPost pending) async {
    // 回复目标只在送审当下的会话里可知(本人可见的服务端接口都不吐,
    // 见 PendingReplyTargetRegistry);冷场景提示用户会退化为直接回复话题。
    final targetKnown = PendingReplyTargetRegistry.contains(pending.id);
    final replyToPostNumber = PendingReplyTargetRegistry.lookup(pending.id);
    final confirmContent = targetKnown
        ? S.current.review_withdrawAndEditConfirmContent
        : '${S.current.review_withdrawAndEditConfirmContent}\n\n'
              '${S.current.review_replyTargetUnknownHint}';

    final withdrawn = await _withdrawPendingPost(
      pending,
      confirmTitle: S.current.review_withdrawAndEdit,
      confirmContent: confirmContent,
      confirmLabel: S.current.review_withdrawAndEdit,
    );
    if (!withdrawn || !mounted) return;
    PendingReplyTargetRegistry.remove(pending.id);

    // 恢复回复目标:优先用已加载楼层,未加载则按楼层号拉取
    Post? replyToPost;
    if (replyToPostNumber != null) {
      final detail = ref.read(topicDetailProvider(_params)).value;
      replyToPost = detail?.postStream.posts
          .where((p) => p.postNumber == replyToPostNumber)
          .firstOrNull;
      if (replyToPost == null) {
        try {
          replyToPost = await DiscourseService().getPostByNumber(
            widget.topicId,
            replyToPostNumber,
          );
        } catch (_) {
          // 目标楼层拉不到(已删除等):退化为直接回复话题并提示
          if (mounted) {
            ToastService.showInfo(S.current.review_replyTargetUnknownHint);
          }
        }
      }
    }
    if (!mounted) return;
    // 原文带回回复编辑器,重新提交后会再次进入审核队列
    await _handleReply(replyToPost, initialContent: pending.raw);
  }

  Future<void> _handleEdit(Post post) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    final updatedPost = await showEditSheet(
      context: context,
      topicId: widget.topicId,
      post: post,
      categoryId: detail?.categoryId,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      isPmWithNonHumanUser: detail?.pmWithNonHumanUser ?? false,
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

      // 触发 Notion 自动同步:话题级 -> 按 syncScope 同步整篇
      unawaited(
        NotionBookmarkAutoSync.tryTriggerTopic(
          ref: ref,
          topicId: widget.topicId,
        ),
      );

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
      // 摘录取当前阅读楼层的正文,不在已加载窗口内则退回首楼
      final viewportPostNumber = _resolvedViewportPostNumber;
      final posts = detail?.postStream.posts;
      final anchorPost = posts == null || posts.isEmpty
          ? null
          : posts.firstWhere(
              (p) => p.postNumber == viewportPostNumber,
              orElse: () => posts.first,
            );
      final item = ReadLaterItem(
        topicId: widget.topicId,
        title: detail?.title ?? widget.initialTitle ?? '',
        scrollToPostNumber: viewportPostNumber,
        excerpt: anchorPost == null
            ? null
            : ReadLaterItem.excerptFromCooked(anchorPost.cooked),
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

  void _handleSharedIssueChanged(int newCount, bool userCreated) {
    final params = _params;
    ref
        .read(topicDetailProvider(params).notifier)
        .updateSharedIssue(newCount, userCreated);
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
      topicTitle: detail?.title,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      isPmWithNonHumanUser: detail?.pmWithNonHumanUser ?? false,
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
      enableDrag: false, // 举报表单:禁止下滑误关丢失输入
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
      topicTitle: detail?.title,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      isPmWithNonHumanUser: detail?.pmWithNonHumanUser ?? false,
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
      topicTitle: detail?.title,
      preloadedDraftFuture: preloadedDraftFuture,
      isPrivateMessageTopic: detail?.isPrivateMessage ?? false,
      isPmWithNonHumanUser: detail?.pmWithNonHumanUser ?? false,
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
    ref
        .read(nestedTopicProvider(nestedParams).notifier)
        .addNewPost(newPost, isOwnPost: true);
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

  /// 批量坍缩阈值:一批里需要逐帖网络刷新的帖子数超过它时,逐条回放
  /// 已没有意义 —— 典型场景是长时间挂后台回前台,msgbus 一次 poll 吐出
  /// 全部积压(热帖几十上百条),逐条 = N 个 /posts/{id} 请求 + N 轮整
  /// 列表重建的几秒卡顿,且逐条中间态早已过时。对齐 message bus 的
  /// reset 语义:一次整流刷新直接取最终态。实时场景一批(一个微任务
  /// 窗口)不同帖的网络类更新极少超过 2~3 条,不会误伤。
  static const _batchCollapseThreshold = 8;

  /// 一批 msgbus 帖子更新的统一入口:去重 → 坍缩判定 → 逐条分发。
  /// 来源两个:频道层微任务攒批(实时/积压)、滚停回放的冻结队列。
  void _handlePostUpdateBatch(
    TopicDetailNotifier notifier,
    List<PostUpdate> updates,
  ) {
    if (updates.isEmpty) return;
    final deduped = _dedupePostUpdates(updates);

    // 统计需要逐帖发网络请求(refreshPost 系)的不同帖子数
    final networkPostIds = <int>{};
    for (final u in deduped) {
      switch (u.type) {
        case TopicMessageType.revised:
        case TopicMessageType.rebaked:
        case TopicMessageType.acted:
        case TopicMessageType.deleted:
        case TopicMessageType.recovered:
        case TopicMessageType.policyChanged:
          networkPostIds.add(u.postId);
          break;
        case TopicMessageType.liked:
        case TopicMessageType.unliked:
          // likesCount 缺失时 updatePostLikes 会退化为 refreshPost
          if (u.likesCount == null) networkPostIds.add(u.postId);
          break;
        default:
          break;
      }
    }
    if (networkPostIds.length > _batchCollapseThreshold) {
      FrameJankMonitor.logEvent(
        'MSGBUS',
        '积压批量 ${updates.length} 条(${networkPostIds.length} 帖需刷新),'
        '坍缩为一次整流刷新',
      );
      // 旧积压全部作废:整流刷新拉回的就是最终态
      _deferredPostUpdates.clear();
      _handleReloadTopic(notifier, true);
      return;
    }

    for (final u in deduped) {
      _handlePostUpdate(notifier, u);
    }
  }

  /// 同帖同类型只留最后一条;boost 是增量事件,逐条保留
  List<PostUpdate> _dedupePostUpdates(List<PostUpdate> updates) {
    final result = <PostUpdate>[];
    final indexByKey = <String, int>{};
    for (final u in updates) {
      if (u.type == TopicMessageType.boostAdded ||
          u.type == TopicMessageType.boostRemoved) {
        result.add(u);
        continue;
      }
      final key = '${u.postId}:${u.type.name}';
      final existing = indexByKey[key];
      if (existing != null) {
        result[existing] = u;
      } else {
        indexByKey[key] = result.length;
        result.add(u);
      }
    }
    return result;
  }

  /// 处理帖子级别的 MessageBus 更新
  void _handlePostUpdate(TopicDetailNotifier notifier, PostUpdate update) {
    // 汇入性能诊断时间轴,定位"message bus 更新是否引发掉帧"
    FrameJankMonitor.logEvent(
      'MSGBUS',
      '${update.type.name} post=${update.postId}',
    );
    // 滚动/惯性滚动进行中,推迟"会改变帖子高度"的更新到滚停后应用:
    // 双向列表里 before-center 区任何帖子高度变化(新 reaction 行、
    // boost 气泡、编辑后内容增减)都会让锚点下方内容整体平移,视觉上
    // 就是滚动中突然"拉一下"(SCROLL-PROBE 抓到的 36~57px 回跳与
    // msgbus/typing 活跃期同窗)。created 不受影响(追加在流末尾,
    // 不在滚动路径上方);滚停后统一放行,交互延迟无感知。
    if (_isUserScrolling && update.type != TopicMessageType.created) {
      _deferredPostUpdates.add(update);
      return;
    }
    _applyPostUpdate(notifier, update);
  }

  bool get _isUserScrolling {
    final sc = _controller.scrollController;
    if (!sc.hasClients) return false;
    return sc.position.isScrollingNotifier.value;
  }

  /// 滚动停止后回放推迟的更新(去重与积压坍缩在批入口统一处理)
  void _flushDeferredPostUpdates(TopicDetailNotifier notifier) {
    if (_deferredPostUpdates.isEmpty) return;
    final batch = List<PostUpdate>.of(_deferredPostUpdates);
    _deferredPostUpdates.clear();
    _handlePostUpdateBatch(notifier, batch);
  }

  void _applyPostUpdate(TopicDetailNotifier notifier, PostUpdate update) {
    // 锚定哨兵的武装(AnchorGuardSliver.arm)不在这里做:acted/revised
    // 等走异步 refreshPost,高度变化在响应落地帧,这里武装会错帧失效。
    // 武装点在 provider 的落地方法(_updatePostById/_applyPostUpdate)。
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
    if (_isNestedView) {
      setState(() => _isNestedView = false);
      _scheduleCheckTitleVisibility();
      return;
    }
    // 四项互斥单选：进入树形视图时清掉内容/顶层筛选，保证同时只有一项生效。
    // （树形视图走独立的 nestedTopicProvider，取消筛选只把底层流恢复成未筛选。）
    final notifier = ref.read(topicDetailProvider(_params).notifier);
    final hadFilter =
        notifier.isSummaryMode ||
        notifier.isAuthorOnlyMode ||
        notifier.isTopLevelMode;
    setState(() => _isNestedView = true);
    if (hadFilter) {
      unawaited(notifier.cancelFilter());
    }
    _scheduleCheckTitleVisibility();
  }
}
