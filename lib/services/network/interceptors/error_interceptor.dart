import 'dart:io';

import 'package:dio/dio.dart';

import '../../toast_service.dart';
import '../exceptions/api_exception.dart';

/// 错误拦截器
/// 处理 429/502/503/504 错误，转换为自定义异常
/// 操作性请求（POST/PUT/DELETE/PATCH）默认显示错误提示
/// 可通过 extra['showErrorToast'] 或 extra['isSilent'] 手动控制
class ErrorInterceptor extends Interceptor {
  /// 操作性请求方法，默认显示错误提示
  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final statusCode = err.response?.statusCode;
    final method = err.requestOptions.method.toUpperCase();
    final extra = err.requestOptions.extra;

    // 静默模式：不显示任何错误提示
    if (extra['isSilent'] == true) {
      handler.next(err);
      return;
    }

    // 判断是否显示错误提示：
    // 1. 如果 extra 中明确指定了 showErrorToast，使用指定的值
    // 2. 否则，操作性请求默认显示
    final showErrorToast = extra.containsKey('showErrorToast')
        ? extra['showErrorToast'] == true
        : _mutationMethods.contains(method);

    // 提取错误信息
    String? errorMessage;
    final data = err.response?.data;
    if (data is Map<String, dynamic>) {
      // Discourse API 错误格式
      errorMessage = data['error'] as String? ??
          (data['errors'] as List?)?.firstOrNull?.toString();
    }

    // 重试耗尽后抛出自定义异常供 UI 层处理
    if (statusCode == 429) {
      final retryAfter = _extractRetryAfterSeconds(err.response);
      if (showErrorToast) {
        final toastMessage = retryAfter != null && retryAfter > 0
            ? '请求过于频繁，请等待 ${_formatWaitDuration(retryAfter)} 后再试'
            : (errorMessage ?? '请求过于频繁，请稍后再试');
        ToastService.showError(toastMessage);
      }
      throw RateLimitException(retryAfter, errorMessage);
    }
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      if (showErrorToast) {
        ToastService.showError(errorMessage ?? '服务器暂时不可用，请稍后再试');
      }
      throw ServerException(statusCode!);
    }

    // 其他错误
    if (showErrorToast) {
      if (errorMessage != null) {
        ToastService.showError(errorMessage);
      } else {
        // 通用错误提示
        final message = switch (statusCode) {
          400 => '请求参数错误',
          401 => '未登录或登录已过期',
          403 => '没有权限执行此操作',
          404 => '请求的资源不存在',
          422 => '请求无法处理',
          500 => '服务器内部错误',
          _ => '请求失败 ($statusCode)',
        };
        ToastService.showError(message);
      }
    }

    handler.next(err);
  }

  int? _extractRetryAfterSeconds(Response? response) {
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

    final resetValue = headers.value('x-ratelimit-reset') ??
        headers.value('ratelimit-reset') ??
        headers.value('x-rate-limit-reset') ??
        headers.value('X-RateLimit-Reset');
    final resetSeconds = int.tryParse(resetValue ?? '');
    if (resetSeconds != null && resetSeconds > 0) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final delta =
          resetSeconds > 1000000000 ? (resetSeconds - nowSeconds) : resetSeconds;
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

  String _formatWaitDuration(int seconds) {
    if (seconds >= 86400) {
      return '${(seconds / 86400).ceil()} 天';
    }
    if (seconds >= 3600) {
      return '${(seconds / 3600).ceil()} 小时';
    }
    if (seconds >= 60) {
      return '${(seconds / 60).ceil()} 分钟';
    }
    return '$seconds 秒';
  }
}
