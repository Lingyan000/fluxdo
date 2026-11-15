import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_policy.dart';

void main() {
  test('敏感字段和 URL 参数统一移除，诊断字段保留', () {
    final row = LogPolicy.normalize({
      'url': 'https://user:password@example.com:8443/image?token=hidden#secret',
      'headers': {'Authorization': 'secret', 'Cookie': 'private'},
      'message': 'failed https://example.com/a?token=private',
      'coreRequestId': 42,
      'statusCode': 403,
    });
    expect(jsonEncode(row), isNot(contains('private')));
    expect(row['url'], 'https://example.com:8443/image');
    expect(row['coreRequestId'], 42);
    expect(row['statusCode'], 403);
    expect(row['schemaVersion'], 2);
  });
  test('导出默认包含保留历史，也可显式选择当前启动，非法行计数', () {
    final current = LogPolicy.normalize({
      'message': 'current',
      'level': 'warning',
    });
    final previous = {
      ...current,
      'sessionId': 'old',
      'message': 'previous',
      'cookie': 'historical-secret',
    };
    final content = '${jsonEncode(previous)}\n${jsonEncode(current)}\nnot-json';
    final full = LogPolicy.export(content);
    expect(full, contains('previous'));
    expect(full, contains('"scope":"retained_history"'));
    expect(full, isNot(contains('historical-secret')));
    final scoped = LogPolicy.export(content, fullHistory: false);
    expect(scoped, contains('current'));
    expect(scoped, isNot(contains('previous')));
    expect(scoped, contains('"invalidLines":1'));
    expect(LogPolicy.export(content, fullHistory: true), contains('previous'));
  });
  test('超大字段有上限且保留关联标识', () {
    final row = LogPolicy.normalize({
      'traceId': 'trace',
      'message': 'x' * 100000,
      'fields': List.filled(64, 'y' * 10000),
    });
    expect(utf8.encode(jsonEncode(row)).length, lessThan(16384));
    expect(row['traceId'], 'trace');
    expect(row['truncated'], true);
  });
}
