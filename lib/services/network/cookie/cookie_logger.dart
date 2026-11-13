import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../log/log_writer.dart';

/// Cookie 模块统一结构化日志。
///
/// 所有 cookie 操作通过此类记录，同时写入 debugPrint（开发调试）
/// 和 LogWriter（持久化 JSONL，用于线上排查）。
class CookieLogger {
  CookieLogger._();

  /// 同一 Cookie 在同步与请求日志中使用相同的短摘要，便于关联。
  static String? valueHash(String? value) => value == null || value.isEmpty
      ? null
      : sha256.convert(utf8.encode(value)).toString().substring(0, 16);

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
    final msg =
        '$name, domain=${domain ?? '<null>'}, '
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
    final msg =
        '$direction, count=$count, names=$names'
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
    entry['level'] = 'debug';
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
  static void flush({required int queued, required int written}) {
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
  static void delete({required String name, required String source}) {
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
  static void error({required String operation, required String error}) {
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

  // ---------------------------------------------------------------------------
  // v0.4.0 Cookie 引擎事件（设计文档 §11.2）
  // ---------------------------------------------------------------------------

  /// Sentinel sweep 事件
  /// [event]: invoked / noop / swept / failed / cancelled
  static void sweep({
    required String event,
    required String url,
    required String name,
    String? intent,
    int? variantsBefore,
    int? variantsAfter,
    String? winnerSource,
    String? reason,
    int? elapsedMs,
    int? entryGeneration,
    int? currentGeneration,
  }) {
    final level = switch (event) {
      'failed' => 'warning',
      // invoked / noop / swept 每次 sweep 都可能产生，记为 debug 仅开发者模式落盘
      'noop' || 'invoked' || 'swept' => 'debug',
      _ => 'info',
    };
    final msg = 'sweep_$event: $name @ $url';
    debugPrint('[Cookie:Sweep] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cookie_engine',
      'event': 'sweep_$event',
      'message': msg,
      'url': url,
      'name': name,
      if (intent != null) 'intent': intent,
      if (variantsBefore != null) 'variantsBefore': variantsBefore,
      if (variantsAfter != null) 'variantsAfter': variantsAfter,
      if (winnerSource != null) 'winnerSource': winnerSource,
      if (reason != null) 'reason': reason,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (entryGeneration != null) 'entryGeneration': entryGeneration,
      if (currentGeneration != null) 'currentGeneration': currentGeneration,
    });
  }

  /// Sentinel Nuclear Reset 事件
  /// [event]: triggered / completed
  static void nuclearReset({
    required String event,
    required String url,
    String? reason,
    int? primingDurationMs,
    int? totalElapsedMs,
  }) {
    final level = 'debug';
    final msg = 'nuclear_reset_$event @ $url';
    debugPrint('[Cookie:Nuclear] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cookie_engine',
      'event': 'nuclear_reset_$event',
      'message': msg,
      'url': url,
      if (reason != null) 'reason': reason,
      if (primingDurationMs != null) 'primingDurationMs': primingDurationMs,
      if (totalElapsedMs != null) 'totalElapsedMs': totalElapsedMs,
    });
  }

  /// WebViewCookiePriming 事件
  /// [event]: invoked / completed / failed
  static void priming({
    required String event,
    required String url,
    bool? isPrimed,
    int? cookiesInjected,
    int? durationMs,
    String? reason,
  }) {
    final level = switch (event) {
      'failed' => 'warning',
      'invoked' => 'debug',
      _ => 'debug',
    };
    final msg = 'priming_$event @ $url';
    debugPrint('[Cookie:Priming] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cookie_engine',
      'event': 'priming_$event',
      'message': msg,
      'url': url,
      if (isPrimed != null) 'isPrimed': isPrimed,
      if (cookiesInjected != null) 'cookiesInjected': cookiesInjected,
      if (durationMs != null) 'durationMs': durationMs,
      if (reason != null) 'reason': reason,
    });
  }

  /// SelfHealingInterceptor 事件
  /// [event]: triggered / retry / success / failed
  static void selfHealing({
    required String event,
    required String url,
    int? status,
    bool? jarHasValidToken,
    bool? hasLoggedOutHeader,
    int? attempt,
    int? attemptsUsed,
    String? finalAction,
  }) {
    final level = switch (event) {
      'failed' => 'warning',
      _ => 'info',
    };
    final msg = 'self_healing_$event @ $url';
    debugPrint('[Cookie:SelfHealing] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cookie_engine',
      'event': 'self_healing_$event',
      'message': msg,
      'url': url,
      if (status != null) 'status': status,
      if (jarHasValidToken != null) 'jarHasValidToken': jarHasValidToken,
      if (hasLoggedOutHeader != null) 'hasLoggedOutHeader': hasLoggedOutHeader,
      if (attempt != null) 'attempt': attempt,
      if (attemptsUsed != null) 'attemptsUsed': attemptsUsed,
      if (finalAction != null) 'finalAction': finalAction,
    });
  }

  /// 区分平台读取超时与 Sentinel 等待锁超时，不包含 Cookie 内容。
  static void readTimeout({required String url, required Duration elapsed}) {
    final host = Uri.parse(url).host;
    final msg = 'cookie_store_read_timeout: $host';
    debugPrint('[Cookie:Read] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_engine',
      'event': 'cookie_store_read_timeout',
      'message': msg,
      'host': host,
      'elapsedMs': elapsed.inMilliseconds,
    });
  }

  /// Sentinel per-name Lock 超时事件
  static void lockTimeout({
    required String name,
    int? consecutiveCount,
    String? currentHolder,
  }) {
    final msg =
        'lock_timeout: $name'
        '${consecutiveCount != null ? ' (consecutive=$consecutiveCount)' : ''}';
    debugPrint('[Cookie:Lock] $msg');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'error',
      'type': 'cookie_engine',
      'event': 'lock_timeout',
      'message': msg,
      'name': name,
      if (consecutiveCount != null) 'consecutiveCount': consecutiveCount,
      if (currentHolder != null) 'currentHolder': currentHolder,
    });
  }
}
