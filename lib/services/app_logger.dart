import 'package:flutter/foundation.dart';

import 'log/log_writer.dart';

/// 统一日志入口
///
/// - `debug()` 控制台总是输出（Debug 模式），仅开发者模式落盘，用于高频追踪
/// - `info()` / `warning()` / `error()` 控制台输出（Debug 模式）+ 写入文件
/// - 所有级别支持 `fields` 附加结构化字段（可覆盖 type 等内置字段），
///   方便在日志页按字段筛选和展示
class AppLogger {
  AppLogger._();

  static bool _enabled = true;

  /// 设置日志开关
  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// 详细日志开关的当前值，原生层（网络核心）据此调整交上来的日志级别
  static final ValueNotifier<bool> verboseNotifier = ValueNotifier(false);

  /// 设置详细日志（debug 级落盘），跟随开发者模式
  static void setVerbose(bool verbose) {
    LogWriter.verboseEnabled = verbose;
    verboseNotifier.value = verbose;
  }

  /// 调试级别日志：高频追踪信息，仅开发者模式落盘
  static void debug(
    String message, {
    String? tag,
    Map<String, dynamic>? fields,
  }) {
    _log('debug', message, tag: tag, fields: fields);
  }

  /// 信息级别日志（控制台 + 文件）
  static void info(
    String message, {
    String? tag,
    Map<String, dynamic>? fields,
  }) {
    _log('info', message, tag: tag, fields: fields);
  }

  /// 警告级别日志（控制台 + 文件）
  static void warning(
    String message, {
    String? tag,
    Map<String, dynamic>? fields,
  }) {
    _log('warning', message, tag: tag, fields: fields);
  }

  /// 错误级别日志（控制台 + 文件，立即落盘）
  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? fields,
  }) {
    if (!_enabled) return;

    if (kDebugMode) {
      debugPrint(_format('ERROR', tag, message));
      if (error != null) debugPrint('  Error: $error');
      if (stackTrace != null) debugPrint('  StackTrace: $stackTrace');
    }

    final trace = stackTrace ?? StackTrace.current;
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'error',
      'type': 'general',
      'message': message,
      if (tag != null) 'tag': tag,
      'error': error?.toString() ?? message,
      'errorType': error?.runtimeType.toString(),
      'stackTrace': trace.toString(),
      ...?fields,
    });
  }

  static void _log(
    String level,
    String message, {
    String? tag,
    Map<String, dynamic>? fields,
  }) {
    if (!_enabled) return;

    if (kDebugMode) {
      debugPrint(_format(level.toUpperCase(), tag, message));
    }

    // 写入文件（fire-and-forget，缓冲批量落盘）
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'general',
      'message': message,
      if (tag != null) 'tag': tag,
      ...?fields,
    });
  }

  /// 格式化日志消息，兼容现有 `debugPrint('[模块名] 消息')` 约定
  static String _format(String level, String? tag, String message) {
    if (tag != null) {
      return '[$tag] $message';
    }
    return '[$level] $message';
  }
}
