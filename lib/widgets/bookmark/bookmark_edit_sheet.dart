import 'package:flutter/material.dart';

import 'package:dio/dio.dart';

import '../../models/bookmark.dart';
import '../../pages/bookmarks/bookmarks_models.dart';
import '../../l10n/s.dart';
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

  const BookmarkEditSheet({
    super.key,
    required this.bookmarkId,
    this.initialName,
    this.initialReminderAt,
    this.nameSuggestions = const [],
    this.nameSuggestionsLoader,
  });

  /// 显示书签编辑 BottomSheet
  static Future<BookmarkEditResult?> show(
    BuildContext context, {
    required int bookmarkId,
    String? initialName,
    DateTime? initialReminderAt,
    List<String> nameSuggestions = const [],
    Future<List<String>> Function()? nameSuggestionsLoader,
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
      ),
    );
  }

  @override
  State<BookmarkEditSheet> createState() => _BookmarkEditSheetState();
}

class _BookmarkEditSheetState extends State<BookmarkEditSheet> {
  late final TextEditingController _nameController;
  BookmarkReminderOption? _selectedReminder;
  DateTime? _customReminderAt;
  DateTime? _currentReminderAt;
  bool _isSaving = false;
  bool _isDeleting = false;
  final DiscourseService _service = DiscourseService();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _currentReminderAt = widget.initialReminderAt;
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
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
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
    try {
      await _service.deleteBookmark(widget.bookmarkId);
      if (mounted) {
        Navigator.pop(context, const BookmarkEditResult(deleted: true));
        ToastService.showSuccess(S.current.bookmark_removed);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<void> _pickCustomDateTime() async {
    final now = DateTime.now();
    final initialDate = _customReminderAt ?? now.add(const Duration(hours: 1));

    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (time == null || !mounted) return;

    setState(() {
      _customReminderAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _currentReminderAt = _customReminderAt;
    });
  }

  void _selectReminder(BookmarkReminderOption option) {
    setState(() {
      if (_selectedReminder == option) {
        // 取消选择
        _selectedReminder = null;
        _currentReminderAt = widget.initialReminderAt;
        return;
      }
      _selectedReminder = option;
      if (option == BookmarkReminderOption.custom) {
        _pickCustomDateTime();
      } else {
        _currentReminderAt = option.toReminderAt();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

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
        child: Padding(
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
                      fontWeight: FontWeight.bold,
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
                    widget.nameSuggestionsLoader ?? _defaultNameSuggestionsLoader,
              ),
              const SizedBox(height: 16),

              // 提醒时间
              Text(
                S.current.bookmark_setReminder,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
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
                    children: [
                      Icon(
                        Icons.alarm,
                        size: 16,
                        color: _currentReminderAt!.isAfter(DateTime.now())
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _currentReminderAt!.isAfter(DateTime.now())
                            ? S.current.bookmark_reminderTime(
                                TimeUtils.formatDetailTime(_currentReminderAt!),
                              )
                            : S.current.bookmark_reminderExpired,
                        style: TextStyle(
                          fontSize: 13,
                          color: _currentReminderAt!.isAfter(DateTime.now())
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      const Spacer(),
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
                      children: [
                        Icon(
                          Icons.alarm,
                          size: 16,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          TimeUtils.formatFullDate(_customReminderAt!),
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: _pickCustomDateTime,
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
              Row(
                children: [
                  // 删除按钮
                  TextButton.icon(
                    onPressed: _isDeleting ? null : _delete,
                    icon: _isDeleting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                    label: Text(
                      S.current.common_delete,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  const Spacer(),
                  // 取消按钮
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(S.current.common_cancel),
                  ),
                  const SizedBox(width: 8),
                  // 保存按钮
                  FilledButton(
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
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
