part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _JumpHistoryActions on _TopicDetailPageState {
  void _clearJumpHistory() {
    _jumpHistory.clear();
    _cancelReadingJump();
  }

  void _cancelReadingJump() {
    _jumpHistory.cancelPending();
    _tocController.cancelJump();
    _controller.cancelPendingScroll();
    _controller.selectKeyboardPostNumber(null);
    _controller.updateSelectedPostIndicator(null);
    _nestedJumpCompletion?.complete(false);
    _nestedJumpCompletion = null;
  }

  TopicReadingPosition? _captureReadingPosition() {
    if (!_isNestedView) return _controller.captureReadingPosition();
    final position = _nestedReadingSession.position;
    if (position == null) return null;
    return TopicReadingPosition(
      postNumber: position.postNumber,
      offset: position.offset,
      nestedPosition: position,
      contextTarget: _nestedTargetPostNumber,
      browsePosition: _nestedBrowsePosition,
    );
  }

  Future<bool> _runReadingJump(
    Future<bool> Function(TopicJumpAttempt attempt) jump, {
    bool returning = false,
  }) async {
    final attempt = _jumpHistory.begin(
      _captureReadingPosition(),
      returning: returning,
    );
    _nestedJumpCompletion?.complete(false);
    _nestedJumpCompletion = null;
    _tocController.cancelJump();
    _controller.cancelPendingScroll();
    var succeeded = false;
    try {
      succeeded = await jump(attempt);
      return succeeded;
    } catch (error) {
      if (mounted && _jumpHistory.isCurrent(attempt)) {
        ToastService.showError(context.l10n.common_loadFailedRetry);
        debugPrint('[TopicDetail] 恢复或跳转阅读位置失败: $error');
      }
      return false;
    } finally {
      if (mounted) {
        if (_jumpHistory.isCurrent(attempt) && (returning || !succeeded)) {
          _controller.selectKeyboardPostNumber(null);
          _controller.updateSelectedPostIndicator(null);
        }
        _jumpHistory.finish(
          attempt,
          succeeded: succeeded,
          destination: _captureReadingPosition(),
        );
      }
    }
  }

  Future<void> _returnToReadingPosition() async {
    final target = _jumpHistory.target;
    if (target == null || _jumpHistory.returning) return;
    await _runReadingJump((attempt) async {
      if (target.nestedPosition != null) {
        return _positionInNestedTopic(
          target.postNumber,
          attempt,
          restorePosition: target.nestedPosition,
          returnPosition: target,
        );
      }
      var loadedForReturn = false;
      if (_isNestedView) {
        final positioned = await _positionAtPost(
          target.postNumber,
          attempt,
          switchToFlat: true,
        );
        if (!positioned || !mounted || !_jumpHistory.isCurrent(attempt)) {
          return false;
        }
        loadedForReturn = true;
      }
      final detail = _positionInfo.detail;
      if (detail == null) return false;
      if (!loadedForReturn &&
          !detail.postStream.posts.any(
            (p) => p.postNumber == target.postNumber,
          )) {
        final index = detail.postStream.stream.indexOf(target.postId ?? -1);
        final loaded = index >= 0
            ? await _loadProgressWindow(detail, index + 1, attempt)
            : await _positionAtPost(target.postNumber, attempt);
        if (!loaded || !mounted || !_jumpHistory.isCurrent(attempt)) {
          return false;
        }
      }
      final current = _positionInfo.detail;
      if (current == null) return false;
      if (!current.postStream.posts.any(
        (p) => p.postNumber == target.postNumber,
      )) {
        // 原楼层删除后，加载入口已经定位到附近仍存在的楼层。
        return true;
      }
      final restored = await _controller.restoreReadingPosition(target);
      if (restored && mounted && _jumpHistory.isCurrent(attempt)) {
        _controller.triggerHighlight(target.postNumber);
      }
      return restored;
    }, returning: true);
  }

  Future<bool> _positionInNestedTopic(
    int postNumber,
    TopicJumpAttempt attempt, {
    NestedReadingPosition? restorePosition,
    TopicReadingPosition? returnPosition,
  }) async {
    if (postNumber <= 1 && returnPosition == null && _isNestedView) {
      await _controller.scrollToTop();
      return _jumpHistory.isCurrent(attempt);
    }
    final contextTarget = returnPosition == null
        ? postNumber
        : returnPosition.contextTarget;
    final params = NestedTopicParams(
      topicId: widget.topicId,
      targetPostNumber: contextTarget,
      instanceId: _instanceId,
    );
    final provider = nestedTopicProvider(params);
    final subscription = ref.listenManual(provider, (_, _) {});
    try {
      // 先加载目标，失败时保留仍可阅读的原列表。
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final state = await ref.read(provider.future);
      if (!mounted || !_jumpHistory.isCurrent(attempt)) return false;
      if (restorePosition != null && state.sort != restorePosition.sort) {
        await ref.read(provider.notifier).changeSort(restorePosition.sort);
        if (!mounted || !_jumpHistory.isCurrent(attempt)) return false;
      }
      final fullTargetPath = contextTarget == null && postNumber > 1
          ? await ref.read(provider.notifier).revealPost(postNumber)
          : null;
      if (!mounted || !_jumpHistory.isCurrent(attempt)) return false;
      final completion = Completer<bool>();
      _nestedJumpCompletion = completion;
      setState(() {
        if (_nestedTargetPostNumber == null) {
          _nestedBrowsePosition = _nestedReadingSession.position;
        }
        _isNestedView = true;
        _nestedAutoEnabled = false;
        _nestedReadingSession.enabled = true;
        _nestedReadingSession.contextTarget = contextTarget;
        if (restorePosition != null) {
          // 列表挂载时按此排序保留要恢复的展开状态。
          if (_nestedReadingSession.sort != restorePosition.sort) {
            _nestedReadingSession.branches.clear();
          }
          _nestedReadingSession.sort = restorePosition.sort;
        }
        _nestedRestorePosition = restorePosition;
        if (returnPosition != null) {
          _nestedBrowsePosition = returnPosition.browsePosition;
          _nestedReadingSession.expanded
            ..clear()
            ..addAll(restorePosition!.expanded);
        }
        _nestedFullTarget = contextTarget == null ? postNumber : null;
        _nestedFullTargetPath = fullTargetPath;
        _nestedRelocateToken++;
        _nestedTargetPostNumber = contextTarget;
      });
      return await completion.future;
    } finally {
      subscription.close();
    }
  }

  void _completeNestedJump(bool succeeded) {
    _nestedJumpCompletion?.complete(succeeded);
    _nestedJumpCompletion = null;
  }
}
