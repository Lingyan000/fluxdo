import 'dart:io';

import 'package:dio/dio.dart';

import '../../log/log_writer.dart';
import '../adapters/adapter_log_metadata.dart';
import '../flux_request_spec.dart';

/// 网络请求日志拦截器，记录每个请求的 method/url/statusCode/duration
class NetworkLogInterceptor extends Interceptor {
  static const String _startTimeKey = '_networkLog_startTime';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startTimeKey] = DateTime.now().millisecondsSinceEpoch;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (!response.requestOptions.spec.skipNetworkLog) {
      // isSilent（MessageBus 长轮询等后台请求）成功属于常态，
      // 记为 debug 避免高频条目淹没日志
      final isSilent = response.requestOptions.spec.isSilent;
      _logRequest(
        options: response.requestOptions,
        statusCode: response.statusCode,
        level: isSilent ? 'debug' : 'info',
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.spec.skipNetworkLog &&
        err.type == DioExceptionType.cancel) {
      handler.next(err);
      return;
    }
    final isSilent = err.requestOptions.spec.isSilent;
    final isTimeout =
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout;

    // cancel: 长轮询频繁 cancel 是正常行为，记录为 debug
    // isSilent + 超时: MessageBus 长轮询超时是正常行为，记录为 debug
    // 其他错误: 记录为 warning
    final level =
        (err.type == DioExceptionType.cancel || (isSilent && isTimeout))
        ? 'debug'
        : 'warning';

    _logRequest(
      options: err.requestOptions,
      statusCode: err.response?.statusCode,
      level: level,
    );
    handler.next(err);
  }

  void _logRequest({
    required RequestOptions options,
    required int? statusCode,
    required String level,
  }) {
    final startTime = options.extra[_startTimeKey] as int?;
    final duration = startTime != null
        ? DateTime.now().millisecondsSinceEpoch - startTime
        : null;

    // URL 脱敏：不记录查询参数
    final uri = options.uri;
    final sanitizedUrl = '${uri.scheme}://${uri.host}${uri.path}';

    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'request',
      'message': '${options.method} ${uri.path}',
      'method': options.method,
      'url': sanitizedUrl,
      'statusCode': statusCode,
      'duration': duration,
    };
    if (uri.path == '/topics/timings') {
      entry.addAll(_timingsDiagnostics(options));
    }
    // 调用方标注的链路标签(csrf-refresh / otp-redeem / preload-home 等),
    // 让日志里能按链路而非仅按 URL 归因。
    final requestTag = options.spec.requestTag;
    if (requestTag != null) {
      entry['requestTag'] = requestTag;
    }
    final extraFields = options.extra['_networkLogFields'];
    if (extraFields is Map) {
      entry.addAll(extraFields.cast<String, dynamic>());
    }
    final adapterName = getRequestAdapterLogName(options);
    if (adapterName != null) {
      entry['networkAdapter'] = adapterName;
    }
    LogWriter.instance.write(entry);
  }

  Map<String, dynamic> _timingsDiagnostics(RequestOptions options) {
    final csrfHeader = options.headers['X-CSRF-Token']?.toString();
    final cookieHeader =
        options.headers[HttpHeaders.cookieHeader]?.toString() ??
        options.headers['Cookie']?.toString() ??
        '';
    final sentT = RegExp(
      r'(?:^|;\s*)_t=([^;]*)',
    ).firstMatch(cookieHeader)?.group(1);

    final csrfState = csrfHeader == null
        ? 'missing'
        : csrfHeader.isEmpty
        ? 'empty'
        : csrfHeader == 'undefined'
        ? 'undefined'
        : 'present';

    return {
      'csrfHeaderState': csrfState,
      if (csrfHeader != null) 'csrfHeaderLen': csrfHeader.length,
      'hasRequestedWith':
          options.headers['X-Requested-With']?.toString() == 'XMLHttpRequest',
      'hasDiscourseLoggedInHeader':
          options.headers['Discourse-Logged-In']?.toString() == 'true',
      'hasDiscoursePresentHeader':
          options.headers['Discourse-Present']?.toString() == 'true',
      'hasCookieHeader': cookieHeader.isNotEmpty,
      'sentCookieLen': cookieHeader.length,
      'sentHasT': sentT != null && sentT.isNotEmpty,
      'sentTLen': sentT?.isNotEmpty == true ? sentT!.length : null,
      'sentHasForumSession': RegExp(
        r'(?:^|;\s*)_forum_session=',
      ).hasMatch(cookieHeader),
    };
  }
}
