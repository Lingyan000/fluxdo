import 'package:flutter/foundation.dart';

import 'log/log_writer.dart';

/// 网络诊断日志门面（DOH 解析 / DOH 代理 / 适配器）
///
/// 输出到统一 JSONL（type: network），在应用日志页按「网络」筛选查看。
/// 历史版本写独立的 network_debug.log 且开关从未被打开，导致网络日志
/// 一直是空的；合并进统一日志后默认生效。
class NetworkLogger {
  NetworkLogger._();

  /// 写入一条网络诊断日志
  static void log(String message, {String level = 'info'}) {
    if (kDebugMode) debugPrint('[Network] $message');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'network',
      'message': message,
    });
  }

  /// 网络核心（Rust）交上来的日志。级别取值见核心的日志回调约定：
  /// 1 error、2 warn、3 info、4 debug。
  static void logCore({
    required int level,
    required String target,
    required String message,
    Map<String, dynamic>? fields,
  }) {
    final levelName = switch (level) {
      1 => 'error',
      2 => 'warning',
      3 => 'info',
      _ => 'debug',
    };
    // 模块名去掉 crate 前缀：fluxdo_net::client → client
    final module = target.startsWith('fluxdo_net::')
        ? target.substring('fluxdo_net::'.length)
        : target;
    if (kDebugMode) debugPrint('[Core/$module] $message');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': levelName,
      'type': 'network',
      ...?fields,
      'tag': 'core',
      'module': module,
      'message': '[Core/$module] $message',
    });
  }

  /// 记录 DOH 解析：成功为 debug 级（高频，仅开发者模式落盘），失败为 warning
  static void logDoh({
    required String host,
    required int durationMs,
    String? resolvedIp,
    String? error,
  }) {
    if (error != null) {
      log('[DOH] ${durationMs}ms FAIL $host | $error', level: 'warning');
    } else {
      log('[DOH] ${durationMs}ms OK $host -> $resolvedIp', level: 'debug');
    }
  }
}
