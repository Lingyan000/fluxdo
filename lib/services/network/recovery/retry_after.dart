import 'dart:io';

import 'package:dio/dio.dart';

/// 从 429/503 响应里解析"还要等多久"。
///
/// linux.do(Discourse)会用多种方式表达这个信息,历史上逐个补齐:
/// - 标准 `Retry-After`(秒数或 HTTP 日期)
/// - `x-ratelimit-reset` 等四种命名变体(秒数或 Unix 时间戳)
/// - 响应体 `extras.wait_seconds` / `extras.time_left`
/// - 响应体报错文案里的中文"请等待 N 秒"或英文 "Please wait N seconds"
///
/// 这套解析原先是 ErrorInterceptor 的私有方法,恢复层的 RateLimitPolicy
/// 需要同一份口径 —— 抽到此处共享,避免出现两套解析结果不一致。

int? extractRetryAfterSeconds(Response? response) {
  if (response == null) return null;
  final headerSeconds = _extractRetryAfterFromHeaders(response.headers);
  if (headerSeconds != null) return headerSeconds;
  return _extractRetryAfterFromData(response.data);
}

int? _extractRetryAfterFromHeaders(Headers headers) {
  final retryAfter =
      headers.value('retry-after') ?? headers.value('Retry-After');
  if (retryAfter != null) {
    final retrySeconds = int.tryParse(retryAfter);
    if (retrySeconds != null && retrySeconds > 0) {
      return retrySeconds;
    }
    try {
      final retryDate = HttpDate.parse(retryAfter);
      final delta = retryDate.difference(DateTime.now()).inSeconds;
      if (delta > 0) return delta;
    } catch (_) {}
  }

  final resetValue =
      headers.value('x-ratelimit-reset') ??
      headers.value('ratelimit-reset') ??
      headers.value('x-rate-limit-reset') ??
      headers.value('X-RateLimit-Reset');
  final resetSeconds = int.tryParse(resetValue ?? '');
  if (resetSeconds != null && resetSeconds > 0) {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final delta = resetSeconds > 1000000000
        ? (resetSeconds - nowSeconds)
        : resetSeconds;
    if (delta > 0) return delta;
  }
  return null;
}

int? _extractRetryAfterFromData(dynamic data) {
  if (data is Map) {
    final extras = data['extras'];
    if (extras is Map) {
      final waitSecondsRaw = extras['wait_seconds'] ?? extras['time_left'];
      final waitSeconds = int.tryParse(waitSecondsRaw?.toString() ?? '');
      if (waitSeconds != null && waitSeconds > 0) {
        return waitSeconds;
      }
    }

    final error = data['error'];
    if (error is String) {
      final parsed = _parseWaitSecondsFromText(error);
      if (parsed != null) return parsed;
    }

    final errors = data['errors'];
    if (errors is List) {
      for (final item in errors) {
        final parsed = _parseWaitSecondsFromText(item.toString());
        if (parsed != null) return parsed;
      }
    } else if (errors is String) {
      final parsed = _parseWaitSecondsFromText(errors);
      if (parsed != null) return parsed;
    }
  }

  if (data is String) {
    return _parseWaitSecondsFromText(data);
  }

  return null;
}

int? _parseWaitSecondsFromText(String message) {
  final chineseMatch = RegExp(
    r'请等待\s*([0-9]+)\s*(天|小时|分钟|秒)',
  ).firstMatch(message);
  if (chineseMatch != null) {
    final value = int.tryParse(chineseMatch.group(1) ?? '');
    final unit = chineseMatch.group(2);
    if (value == null || unit == null) return null;
    return _secondsFromUnit(value, unit);
  }

  final englishMatch = RegExp(
    r'Please wait\s+(\d+)\s+(second|seconds|minute|minutes|hour|hours|day|days)',
    caseSensitive: false,
  ).firstMatch(message);
  if (englishMatch != null) {
    final value = int.tryParse(englishMatch.group(1) ?? '');
    final unit = englishMatch.group(2)?.toLowerCase();
    if (value == null || unit == null) return null;
    return _secondsFromUnit(value, unit);
  }

  return null;
}

int _secondsFromUnit(int value, String unit) {
  if (unit.contains('天') || unit.startsWith('day')) {
    return value * 86400;
  }
  if (unit.contains('小时') || unit.startsWith('hour')) {
    return value * 3600;
  }
  if (unit.contains('分钟') || unit.startsWith('minute')) {
    return value * 60;
  }
  return value;
}
