import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/bookmark_edit_trace.dart';

void main() {
  test('编辑书签 trace 日志会保留关键上下文字段且脱敏书签名', () {
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
    expect(entry['bookmarkName'], {'length': 5, 'isEmpty': false});
    expect(entry['selectedAction'], 'bookmark');
    expect(entry['cachedSuggestionCount'], 3);
  });

  test('书签名脱敏不会把原文写入日志', () {
    final entry = buildBookmarkEditTraceEntry(
      phase: 'sheet_init',
      traceId: 'trace',
      source: 'src',
      message: 'init',
      initialName: '我的私密笔记',
      bookmarkName: '账号密码',
      resultName: 'whatever',
    );

    expect(entry.values.contains('我的私密笔记'), isFalse);
    expect(entry.values.contains('账号密码'), isFalse);
    expect(entry.values.contains('whatever'), isFalse);
    expect(entry['initialName'], {'length': 6, 'isEmpty': false});
    expect(entry['bookmarkName'], {'length': 4, 'isEmpty': false});
    expect(entry['resultName'], {'length': 8, 'isEmpty': false});
  });

  test('null 书签名脱敏后不会出现在 entry 里', () {
    final entry = buildBookmarkEditTraceEntry(
      phase: 'sheet_init',
      traceId: 'trace',
      source: 'src',
      message: 'init',
    );

    expect(entry.containsKey('bookmarkName'), isFalse);
    expect(entry.containsKey('initialName'), isFalse);
    expect(entry.containsKey('resultName'), isFalse);
  });

  test('空字符串书签名脱敏后保留 length=0 与 isEmpty=true', () {
    final entry = buildBookmarkEditTraceEntry(
      phase: 'sheet_save',
      traceId: 'trace',
      source: 'src',
      message: 'save',
      bookmarkName: '',
    );

    expect(entry['bookmarkName'], {'length': 0, 'isEmpty': true});
  });
}
