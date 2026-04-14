import 'package:flutter/foundation.dart';

import '../../log/log_writer.dart';

/// Cookie 模块统一结构化日志。
///
/// 所有 cookie 操作通过此类记录，同时写入 debugPrint（开发调试）
/// 和 LogWriter（持久化 JSONL，用于线上排查）。
class CookieLogger {
  CookieLogger._();

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /// cookie 写入 jar
  static void save({
    required String name,
    String? domain,
    bool? hostOnly,
    required String source,
    required int valueLength,
    bool replaced = false,
  }) {
    final msg = '$name, domain=${domain ?? '<null>'}, '
        'hostOnly=$hostOnly, source=$source, len=$valueLength'
        '${replaced ? ', replaced=true' : ''}';
    debugPrint('[Cookie:Save] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'cookie_trace',
      'event': 'cookie_save',
      'message': msg,
      'name': name,
      'domain': domain,
      'hostOnly': hostOnly,
      'source': source,
      'valueLength': valueLength,
      'replaced': replaced,
    });
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  /// 请求发送前加载 cookie
  static void load({
    required String url,
    required int count,
    required List<String> names,
  }) {
    debugPrint('[Cookie:Load] $url, count=$count, names=$names');
  }

  // ---------------------------------------------------------------------------
  // 边界同步
  // ---------------------------------------------------------------------------

  /// WebView → jar 边界同步
  static void sync({
    required String direction,
    required int count,
    required List<String> names,
    required String source,
    String? url,
    List<Map<String, dynamic>>? cookieDetails,
    Map<String, dynamic>? extraFields,
  }) {
    final msg = '$direction, count=$count, names=$names'
        '${url != null ? ', url=$url' : ''}';
    debugPrint('[Cookie:Sync] $msg');
    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'cookie_trace',
      'event': 'cookie_sync',
      'message': msg,
      'direction': direction,
      'count': count,
      'names': names,
      'source': source,
      'url': url,
      ...?(cookieDetails != null ? {'cookieDetails': cookieDetails} : null),
    };
    if (extraFields != null && extraFields.isNotEmpty) {
      entry.addAll(extraFields);
    }
    LogWriter.instance.write(entry);
  }

  // ---------------------------------------------------------------------------
  // 队列
  // ---------------------------------------------------------------------------

  /// 原始头入队
  static void enqueue({
    required String name,
    required String url,
    required int queueSize,
  }) {
    debugPrint('[Cookie:Queue] enqueue $name for $url, queueSize=$queueSize');
  }

  /// 队列 flush 到 WebView
  static void flush({
    required int queued,
    required int written,
  }) {
    final msg = 'queued=$queued, written=$written';
    debugPrint('[Cookie:Flush] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'cookie_trace',
      'event': 'cookie_flush',
      'message': msg,
      'queued': queued,
      'written': written,
    });
  }

  // ---------------------------------------------------------------------------
  // 删除 / 清理
  // ---------------------------------------------------------------------------

  /// cookie 删除
  static void delete({
    required String name,
    required String source,
  }) {
    debugPrint('[Cookie:Delete] $name, source=$source');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'cookie_trace',
      'event': 'cookie_delete',
      'message': '$name, source=$source',
      'name': name,
      'source': source,
    });
  }

  // ---------------------------------------------------------------------------
  // 错误
  // ---------------------------------------------------------------------------

  /// cookie 操作错误
  static void error({
    required String operation,
    required String error,
  }) {
    debugPrint('[Cookie:Error] $operation: $error');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'error',
      'type': 'cookie_trace',
      'event': 'cookie_error',
      'message': '$operation: $error',
      'operation': operation,
      'error': error,
    });
  }
}
