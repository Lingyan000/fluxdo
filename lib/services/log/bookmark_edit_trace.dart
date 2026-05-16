import 'log_writer.dart';

const String bookmarkEditTraceTag = 'bookmark_edit_trace';

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
    'bookmarkName':? bookmarkName,
    'initialName':? initialName,
    'bookmarked':? bookmarked,
    'hasReminder':? hasReminder,
    'selectedAction':? selectedAction,
    'cachedSuggestionCount':? cachedSuggestionCount,
    'seedTopicCount':? seedTopicCount,
    'deleted':? deleted,
    'resultName':? resultName,
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
