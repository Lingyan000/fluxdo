import 'package:flutter/material.dart';

import 'package:dio/dio.dart';

import '../../models/bookmark.dart';
import '../../pages/bookmarks/bookmarks_models.dart';
import '../../l10n/s.dart';
import '../../services/log/bookmark_edit_trace.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../../services/app_error_handler.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/time_utils.dart';
import 'bookmark_name_edit_panel.dart';

/// 书签编辑结果
class BookmarkEditResult {
  final String? name;
  final DateTime? reminderAt;
  final bool deleted;

  const BookmarkEditResult({this.name, this.reminderAt, this.deleted = false});
}

/// 书签编辑 BottomSheet
class BookmarkEditSheet extends StatefulWidget {
  final int bookmarkId;
  final String? initialName;
  final DateTime? initialReminderAt;
  final List<String> nameSuggestions;
  final Future<List<String>> Function()? nameSuggestionsLoader;
  final String? traceId;
  final String? traceSource;
  final int? topicId;
  final int? postId;

  const BookmarkEditSheet({
    super.key,
    required this.bookmarkId,
    this.initialName,
    this.initialReminderAt,
    this.nameSuggestions = const [],
    this.nameSuggestionsLoader,
    this.traceId,
    this.traceSource,
    this.topicId,
    this.postId,
  });

  /// 显示书签编辑 BottomSheet
  static Future<BookmarkEditResult?> show(
    BuildContext context, {
    required int bookmarkId,
    String? initialName,
    DateTime? initialReminderAt,
    List<String> nameSuggestions = const [],
    Future<List<String>> Function()? nameSuggestionsLoader,
    String? traceId,
    String? traceSource,
    int? topicId,
    int? postId,
  }) {
    return showAppBottomSheet<BookmarkEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => BookmarkEditSheet(
        bookmarkId: bookmarkId,
        initialName: initialName,
        initialReminderAt: initialReminderAt,
        nameSuggestions: nameSuggestions,
        nameSuggestionsLoader: nameSuggestionsLoader,
        traceId: traceId,
        traceSource: traceSource,
        topicId: topicId,
        postId: postId,
      ),
    );
  }

  @override
  State<BookmarkEditSheet> createState() => _BookmarkEditSheetState();
}

class _BookmarkEditSheetState extends State<BookmarkEditSheet> {
  static const double _compactLayoutWidth = 360;

  late final TextEditingController _nameController;
  BookmarkReminderOption? _selectedReminder;
  DateTime? _customReminderAt;
  DateTime? _currentReminderAt;
  bool _isSaving = false;
  bool _isDeleting = false;
  final DiscourseService _service = DiscourseService();

  String get _traceId => widget.traceId ?? 'bookmark-edit-missing-trace';

  String get _traceSource => widget.traceSource ?? 'bookmark_sheet';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: normalizeBookmarkName(widget.initialName) ?? '',
    );
    _currentReminderAt = widget.initialReminderAt;
    writeBookmarkEditTrace(
      phase: 'sheet_init',
      traceId: _traceId,
      source: _traceSource,
      message: '编辑书签面板已初始化',
      topicId: widget.topicId,
      postId: widget.postId,
      bookmarkId: widget.bookmarkId,
      initialName: widget.initialName,
      hasReminder: widget.initialReminderAt != null,
      cachedSuggestionCount: widget.nameSuggestions.length,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<List<String>> _defaultNameSuggestionsLoader() async {
    final topics = await loadAllBookmarkTopics(
      loadPage: (page, limit) =>
          _service.getUserBookmarks(page: page, limit: limit),
    );
    return buildBookmarkNameSuggestions(topics);
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    writeBookmarkEditTrace(
      phase: 'sheet_save_start',
      traceId: _traceId,
      source: _traceSource,
      message: '编辑书签面板开始保存',
      topicId: widget.topicId,
      postId: widget.postId,
      bookmarkId: widget.bookmarkId,
      bookmarkName: _nameController.text.trim(),
    );

    try {
      // 计算提醒时间
      DateTime? reminderAt = _currentReminderAt;
      if (_selectedReminder != null &&
          _selectedReminder != BookmarkReminderOption.custom) {
        reminderAt = _selectedReminder!.toReminderAt();
      } else if (_selectedReminder == BookmarkReminderOption.custom &&
          _customReminderAt != null) {
        reminderAt = _customReminderAt;
      }

      final name = _nameController.text.trim();

      await _service.updateBookmark(
        widget.bookmarkId,
        name: name,
        reminderAt: reminderAt,
      );

      if (mounted) {
        writeBookmarkEditTrace(
          phase: 'sheet_save_success',
          traceId: _traceId,
          source: _traceSource,
          message: '编辑书签面板保存成功',
          topicId: widget.topicId,
          postId: widget.postId,
          bookmarkId: widget.bookmarkId,
          resultName: name.isNotEmpty ? name : null,
          hasReminder: reminderAt != null,
        );
        Navigator.pop(
          context,
          BookmarkEditResult(
            name: name.isNotEmpty ? name : null,
            reminderAt: reminderAt,
          ),
        );
        ToastService.showSuccess(S.current.common_bookmarkUpdated);
      }
    } on DioException catch (_) {
      // ErrorInterceptor 默认对 PUT/POST/DELETE/PATCH 弹出错误 toast，这里
      // 故意不二次弹 toast 避免重复；同时保留 sheet 打开让用户修改后重试。
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'sheet_save_dio_error',
        traceId: _traceId,
        source: _traceSource,
        message: '编辑书签面板保存失败',
        topicId: widget.topicId,
        postId: widget.postId,
        bookmarkId: widget.bookmarkId,
      );
    } catch (e, s) {
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'sheet_save_throw',
        traceId: _traceId,
        source: _traceSource,
        message: '编辑书签面板保存时抛出异常',
        topicId: widget.topicId,
        postId: widget.postId,
        bookmarkId: widget.bookmarkId,
        error: e,
        stackTrace: s,
      );
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _delete() async {
    if (_isDeleting) return;

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.common_deleteBookmark),
        content: Text(S.current.bookmark_deleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(S.current.common_delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    writeBookmarkEditTrace(
      phase: 'sheet_delete_start',
      traceId: _traceId,
      source: _traceSource,
      message: '编辑书签面板开始删除书签',
      topicId: widget.topicId,
      postId: widget.postId,
      bookmarkId: widget.bookmarkId,
    );
    try {
      await _service.deleteBookmark(widget.bookmarkId);
      if (mounted) {
        writeBookmarkEditTrace(
          phase: 'sheet_delete_success',
          traceId: _traceId,
          source: _traceSource,
          message: '编辑书签面板删除书签成功',
          topicId: widget.topicId,
          postId: widget.postId,
          bookmarkId: widget.bookmarkId,
          deleted: true,
        );
        Navigator.pop(context, const BookmarkEditResult(deleted: true));
        ToastService.showSuccess(S.current.bookmark_removed);
      }
    } on DioException catch (_) {
      // ErrorInterceptor 默认对 DELETE 弹出错误 toast，这里故意不二次弹避免
      // 重复；同时保留 sheet 打开让用户重试删除。
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'sheet_delete_dio_error',
        traceId: _traceId,
        source: _traceSource,
        message: '编辑书签面板删除书签失败',
        topicId: widget.topicId,
        postId: widget.postId,
        bookmarkId: widget.bookmarkId,
      );
    } catch (e, s) {
      writeBookmarkEditTrace(
        level: 'error',
        phase: 'sheet_delete_throw',
        traceId: _traceId,
        source: _traceSource,
        message: '编辑书签面板删除书签时抛出异常',
        topicId: widget.topicId,
        postId: widget.postId,
        bookmarkId: widget.bookmarkId,
        error: e,
        stackTrace: s,
      );
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<DateTime?> _pickCustomDateTime() async {
    final now = DateTime.now();
    final initialDate = _customReminderAt ?? now.add(const Duration(hours: 1));

    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (time == null || !mounted) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  /// 已选 custom 时，再次点击 edit 图标走这个入口：弹 picker 并应用结果。
  /// 不与 [_selectReminder] 走"取消选择"分支冲突。
  Future<void> _pickAndApplyCustomDateTime() async {
    final picked = await _pickCustomDateTime();
    if (!mounted || picked == null) return;
    setState(() {
      _customReminderAt = picked;
      _currentReminderAt = picked;
      _selectedReminder ??= BookmarkReminderOption.custom;
    });
  }

  Future<void> _selectReminder(BookmarkReminderOption option) async {
    if (_selectedReminder == option) {
      // 再次点击同一选项视为取消
      setState(() {
        _selectedReminder = null;
        _currentReminderAt = widget.initialReminderAt;
      });
      return;
    }
    if (option == BookmarkReminderOption.custom) {
      // 先 await picker 拿到结果再 setState，避免出现"已选 custom 但无时间"的闪烁；
      // 用户取消 picker 时不更新选中状态，保持原值。
      final picked = await _pickCustomDateTime();
      if (!mounted || picked == null) {
        return;
      }
      setState(() {
        _selectedReminder = option;
        _customReminderAt = picked;
        _currentReminderAt = picked;
      });
      return;
    }
    setState(() {
      _selectedReminder = option;
      _currentReminderAt = option.toReminderAt();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final maxSheetHeight =
        mediaQuery.size.height -
        mediaQuery.padding.top -
        mediaQuery.padding.bottom -
        bottomInset -
        32;
    final compactLayout = mediaQuery.size.width < _compactLayoutWidth;

    final deleteButton = TextButton.icon(
      onPressed: _isDeleting ? null : _delete,
      icon: _isDeleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.delete_outline, color: theme.colorScheme.error),
      label: Text(
        S.current.common_delete,
        style: TextStyle(color: theme.colorScheme.error),
      ),
    );
    final cancelButton = TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(S.current.common_cancel),
    );
    final saveButton = FilledButton(
      onPressed: _isSaving ? null : _save,
      child: _isSaving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(S.current.common_save),
    );

    return Container(
      margin: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + bottomInset,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxSheetHeight.clamp(280, double.infinity),
          ),
          child: SingleChildScrollView(
            // 允许书签名称候选列表自己处理拖拽，避免外层滚动先收起键盘导致补全浮层失焦。
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题栏
                Row(
                  children: [
                    Icon(Icons.bookmark, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      S.current.bookmark_editBookmark,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 书签名称
                BookmarkNameEditPanel(
                  controller: _nameController,
                  initialSuggestions: widget.nameSuggestions,
                  suggestionsLoader:
                      widget.nameSuggestionsLoader ??
                      _defaultNameSuggestionsLoader,
                ),
                const SizedBox(height: 16),

                // 提醒时间
                Text(
                  S.current.bookmark_setReminder,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),

                // 当前提醒时间显示
                if (_currentReminderAt != null && _selectedReminder == null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: _currentReminderAt!.isAfter(DateTime.now())
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.alarm,
                          size: 16,
                          color: _currentReminderAt!.isAfter(DateTime.now())
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _currentReminderAt!.isAfter(DateTime.now())
                                ? S.current.bookmark_reminderTime(
                                    TimeUtils.formatDetailTime(
                                      _currentReminderAt!,
                                    ),
                                  )
                                : S.current.bookmark_reminderExpired,
                            style: TextStyle(
                              fontSize: 13,
                              color: _currentReminderAt!.isAfter(DateTime.now())
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _currentReminderAt = null;
                            });
                          },
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: _currentReminderAt!.isAfter(DateTime.now())
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),

                // 快捷提醒选项
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: BookmarkReminderOption.values.map((option) {
                    final isSelected = _selectedReminder == option;
                    return ChoiceChip(
                      label: Text(option.label),
                      selected: isSelected,
                      onSelected: (_) => _selectReminder(option),
                    );
                  }).toList(),
                ),

                // 自定义时间显示
                if (_selectedReminder == BookmarkReminderOption.custom &&
                    _customReminderAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.alarm,
                            size: 16,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              TimeUtils.formatFullDate(_customReminderAt!),
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _pickAndApplyCustomDateTime,
                            child: Icon(
                              Icons.edit,
                              size: 16,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // 按钮区域
                if (compactLayout) ...[
                  SizedBox(width: double.infinity, child: saveButton),
                  const SizedBox(height: 8),
                  Row(children: [deleteButton, const Spacer(), cancelButton]),
                ] else
                  Row(
                    children: [
                      deleteButton,
                      const Spacer(),
                      cancelButton,
                      const SizedBox(width: 8),
                      saveButton,
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
