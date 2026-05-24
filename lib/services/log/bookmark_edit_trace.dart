import 'log_writer.dart';

const String bookmarkEditTraceTag = 'bookmark_edit_trace';

/// 把用户书签名脱敏成可观测的统计信息，避免原文落到持久日志里。
///
/// 返回 null 表示原值就是 null（与"空字符串"区分开）。
Map<String, dynamic>? _redactBookmarkName(String? value) {
  if (value == null) return null;
  return <String, dynamic>{
    'length': value.length,
    'isEmpty': value.isEmpty,
  };
}

Map<String, dynamic> buildBookmarkEditTraceEntry({
  DateTime? timestamp,
  String level = 'info',
  required String phase,
  required String traceId,
  required String source,
  required String message,
  int? topicId,
  int? postId,
  int? bookmarkId,
  String? bookmarkName,
  String? initialName,
  bool? bookmarked,
  bool? hasReminder,
  String? selectedAction,
  int? cachedSuggestionCount,
  int? seedTopicCount,
  bool? deleted,
  String? resultName,
  Object? error,
  StackTrace? stackTrace,
}) {
  return {
    'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
    'level': level,
    'type': 'general',
    'tag': bookmarkEditTraceTag,
    'phase': phase,
    'traceId': traceId,
    'source': source,
    'message': message,
    'topicId':? topicId,
    'postId':? postId,
    'bookmarkId':? bookmarkId,
    // 书签名脱敏：只记录长度统计，不写原文到持久日志。
    'bookmarkName':? _redactBookmarkName(bookmarkName),
    'initialName':? _redactBookmarkName(initialName),
    'resultName':? _redactBookmarkName(resultName),
    'bookmarked':? bookmarked,
    'hasReminder':? hasReminder,
    'selectedAction':? selectedAction,
    'cachedSuggestionCount':? cachedSuggestionCount,
    'seedTopicCount':? seedTopicCount,
    'deleted':? deleted,
    'error':? error?.toString(),
    'stackTrace':? stackTrace?.toString(),
  };
}

void writeBookmarkEditTrace({
  String level = 'info',
  required String phase,
  required String traceId,
  required String source,
  required String message,
  int? topicId,
  int? postId,
  int? bookmarkId,
  String? bookmarkName,
  String? initialName,
  bool? bookmarked,
  bool? hasReminder,
  String? selectedAction,
  int? cachedSuggestionCount,
  int? seedTopicCount,
  bool? deleted,
  String? resultName,
  Object? error,
  StackTrace? stackTrace,
}) {
  LogWriter.instance.write(
    buildBookmarkEditTraceEntry(
      level: level,
      phase: phase,
      traceId: traceId,
      source: source,
      message: message,
      topicId: topicId,
      postId: postId,
      bookmarkId: bookmarkId,
      bookmarkName: bookmarkName,
      initialName: initialName,
      bookmarked: bookmarked,
      hasReminder: hasReminder,
      selectedAction: selectedAction,
      cachedSuggestionCount: cachedSuggestionCount,
      seedTopicCount: seedTopicCount,
      deleted: deleted,
      resultName: resultName,
      error: error,
      stackTrace: stackTrace,
    ),
  );
}

String createBookmarkEditTraceId() {
  return 'bookmark-edit-${DateTime.now().microsecondsSinceEpoch}';
}
