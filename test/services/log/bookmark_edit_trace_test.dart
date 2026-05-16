import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/bookmark_edit_trace.dart';

void main() {
  test('编辑书签 trace 日志会保留关键上下文字段', () {
    final entry = buildBookmarkEditTraceEntry(
      timestamp: DateTime.utc(2026, 5, 15, 8, 0, 0),
      phase: 'menu_selected',
      traceId: 'bookmark-edit-123',
      source: 'topic_detail_topic_menu',
      message: '编辑书签菜单已选中',
      topicId: 42,
      bookmarkId: 1001,
      bookmarkName: 'image',
      selectedAction: 'bookmark',
      cachedSuggestionCount: 3,
    );

    expect(entry['timestamp'], '2026-05-15T08:00:00.000Z');
    expect(entry['level'], 'info');
    expect(entry['type'], 'general');
    expect(entry['tag'], 'bookmark_edit_trace');
    expect(entry['phase'], 'menu_selected');
    expect(entry['traceId'], 'bookmark-edit-123');
    expect(entry['source'], 'topic_detail_topic_menu');
    expect(entry['message'], '编辑书签菜单已选中');
    expect(entry['topicId'], 42);
    expect(entry['bookmarkId'], 1001);
    expect(entry['bookmarkName'], 'image');
    expect(entry['selectedAction'], 'bookmark');
    expect(entry['cachedSuggestionCount'], 3);
  });
}
