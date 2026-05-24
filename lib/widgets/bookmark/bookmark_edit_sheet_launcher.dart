import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/topic.dart';
import '../../providers/bookmark_name_suggestions_provider.dart';
import '../../providers/bookmarks_repository.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/log/bookmark_edit_trace.dart';
import '../../providers/core_providers.dart';
import 'bookmark_edit_sheet.dart';

Future<BookmarkEditResult?> showBookmarkEditSheetWithCachedNames(
  BuildContext context,
  WidgetRef ref, {
  required int bookmarkId,
  String? initialName,
  DateTime? initialReminderAt,
  List<Topic> seedTopics = const [],
  String? traceId,
  String source = 'bookmark_launcher',
  int? topicId,
  int? postId,
}) async {
  final resolvedTraceId = traceId ?? createBookmarkEditTraceId();
  final suggestionsNotifier = ref.read(
    bookmarkNameSuggestionsProvider.notifier,
  );
  if (seedTopics.isNotEmpty) {
    suggestionsNotifier.seedFromTopics(seedTopics);
  }
  suggestionsNotifier.rememberName(initialName);
  final cachedSuggestions = ref.read(bookmarkNameSuggestionsProvider);

  writeBookmarkEditTrace(
    phase: 'launcher_prepare',
    traceId: resolvedTraceId,
    source: source,
    message: '准备打开编辑书签面板',
    topicId: topicId,
    postId: postId,
    bookmarkId: bookmarkId,
    initialName: initialName,
    hasReminder: initialReminderAt != null,
    cachedSuggestionCount: cachedSuggestions.length,
    seedTopicCount: seedTopics.length,
  );

  BookmarkEditResult? result;
  try {
    result = await BookmarkEditSheet.show(
      context,
      bookmarkId: bookmarkId,
      initialName: initialName,
      initialReminderAt: initialReminderAt,
      nameSuggestions: cachedSuggestions,
      nameSuggestionsLoader: suggestionsNotifier.ensureLoaded,
      traceId: resolvedTraceId,
      traceSource: source,
      topicId: topicId,
      postId: postId,
    );
  } catch (e, s) {
    writeBookmarkEditTrace(
      level: 'error',
      phase: 'launcher_throw',
      traceId: resolvedTraceId,
      source: source,
      message: '打开编辑书签面板时抛出异常',
      topicId: topicId,
      postId: postId,
      bookmarkId: bookmarkId,
      initialName: initialName,
      error: e,
      stackTrace: s,
    );
    rethrow;
  }

  if (result == null) {
    writeBookmarkEditTrace(
      phase: 'launcher_dismissed',
      traceId: resolvedTraceId,
      source: source,
      message: '编辑书签面板已关闭且未返回结果',
      topicId: topicId,
      postId: postId,
      bookmarkId: bookmarkId,
      initialName: initialName,
    );
    return null;
  }

  if (result.deleted) {
    suggestionsNotifier.markDirty();
  } else {
    suggestionsNotifier.markDirty(optimisticName: result.name);
  }

  // 统一写穿透 BookmarksRepository：所有书签编辑入口（书签页 / 详情页 /
  // 帖子 footer / 预览卡）共用 launcher，本地缓存的同步收敛在这一处。
  await _syncToBookmarkRepository(
    ref,
    bookmarkId: bookmarkId,
    result: result,
  );

  writeBookmarkEditTrace(
    phase: 'launcher_completed',
    traceId: resolvedTraceId,
    source: source,
    message: '编辑书签面板返回结果',
    topicId: topicId,
    postId: postId,
    bookmarkId: bookmarkId,
    deleted: result.deleted,
    resultName: result.name,
    hasReminder: result.reminderAt != null,
  );
  return result;
}

Future<void> _syncToBookmarkRepository(
  WidgetRef ref, {
  required int bookmarkId,
  required BookmarkEditResult result,
}) async {
  final DiscourseService service = ref.read(discourseServiceProvider);
  final accountId = await service.getUsername();
  if (accountId == null) return;
  final repo = ref.read(bookmarksRepositoryProvider);
  if (result.deleted) {
    await repo.deleteOne(accountId, bookmarkId);
    return;
  }
  await repo.applyMetadataChange(
    accountId,
    bookmarkId,
    name: result.name,
    reminderAt: result.reminderAt,
    bookmarkUpdatedAt: DateTime.now().toUtc(),
  );
}
