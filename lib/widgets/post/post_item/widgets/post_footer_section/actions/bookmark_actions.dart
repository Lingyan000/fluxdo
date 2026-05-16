// ignore_for_file: invalid_use_of_protected_member, unused_element

part of '../post_footer_section.dart';

extension _PostFooterBookmarkActions on _PostFooterSectionState {
  /// 添加书签并弹出编辑 BottomSheet
  Future<void> _addBookmark() async {
    if (_isBookmarking) return;

    HapticFeedback.lightImpact();
    setState(() => _isBookmarking = true);

    try {
      final bookmarkId = await _service.bookmarkPost(widget.post.id);
      if (!mounted) return;

      setState(() {
        _isBookmarked = true;
        _bookmarkId = bookmarkId;
        _bookmarkName = null;
        _bookmarkReminderAt = null;
      });
      ToastService.showSuccess(S.current.common_bookmarkAdded);

      // 弹出编辑 BottomSheet
      _showBookmarkSheet(bookmarkId);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isBookmarking = false);
    }
  }

  /// 删除书签
  Future<void> _removeBookmark() async {
    if (_isBookmarking) return;

    HapticFeedback.lightImpact();
    setState(() => _isBookmarking = true);

    try {
      final bookmarkId = _bookmarkId ?? widget.post.bookmarkId;
      if (bookmarkId != null) {
        await _service.deleteBookmark(bookmarkId);
        if (mounted) {
          setState(() {
            _isBookmarked = false;
            _bookmarkId = null;
            _bookmarkName = null;
            _bookmarkReminderAt = null;
          });
          ToastService.showSuccess(S.current.common_bookmarkRemoved);
        }
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isBookmarking = false);
    }
  }

  /// 编辑已有书签
  Future<void> _editBookmark() async {
    final bookmarkId = _bookmarkId ?? widget.post.bookmarkId;
    if (bookmarkId == null) return;
    _showBookmarkSheet(bookmarkId, isEdit: true);
  }

  /// 弹出书签编辑 BottomSheet
  Future<void> _showBookmarkSheet(int bookmarkId, {bool isEdit = false}) async {
    final traceId = createBookmarkEditTraceId();
    writeBookmarkEditTrace(
      phase: 'post_footer_bookmark_sheet_request',
      traceId: traceId,
      source: 'post_footer_bookmark_action',
      message: isEdit ? '帖子 footer 准备打开编辑书签面板' : '帖子 footer 准备打开新建书签编辑面板',
      topicId: widget.topicId,
      postId: widget.post.id,
      bookmarkId: bookmarkId,
      bookmarkName: _bookmarkName ?? widget.post.bookmarkName,
      initialName: isEdit ? (_bookmarkName ?? widget.post.bookmarkName) : null,
      bookmarked: _isBookmarked,
      hasReminder:
          isEdit
              ? ((_bookmarkReminderAt ?? widget.post.bookmarkReminderAt) != null)
              : false,
    );
    final result = await showBookmarkEditSheetWithCachedNames(
      context,
      ref,
      bookmarkId: bookmarkId,
      initialName: isEdit ? (_bookmarkName ?? widget.post.bookmarkName) : null,
      initialReminderAt: isEdit
          ? (_bookmarkReminderAt ?? widget.post.bookmarkReminderAt)
          : null,
      traceId: traceId,
      source: 'post_footer_bookmark_action',
      topicId: widget.topicId,
      postId: widget.post.id,
    );

    if (result == null || !mounted) return;

    if (result.deleted) {
      setState(() {
        _isBookmarked = false;
        _bookmarkId = null;
        _bookmarkName = null;
        _bookmarkReminderAt = null;
      });
    } else {
      setState(() {
        _bookmarkName = result.name;
        _bookmarkReminderAt = result.reminderAt;
      });
    }
  }

}
