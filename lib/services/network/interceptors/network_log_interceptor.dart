import 'dart:io';

import 'package:dio/dio.dart';

import '../../log/log_writer.dart';
import '../../log/log_policy.dart';
import '../adapters/adapter_log_metadata.dart';
import '../core/net_core_http_adapter.dart';
import '../flux_request_spec.dart';
import '../deadline_dio.dart';
import '../cookie/csrf_session_trace.dart';

/// 网络请求日志拦截器，记录每个请求的 method/url/statusCode/duration
class NetworkLogInterceptor extends Interceptor {
  static const String _startTimeKey = '_networkLog_startTime';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra.putIfAbsent('traceId', LogPolicy.newTraceId);
    options.extra['attemptId'] = LogPolicy.newTraceId();
    options.extra[_startTimeKey] = Stopwatch()..start();
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
        responseExtra: response.extra,
        responseHeaders: response.headers,
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final deadlineExceeded = err.error is CallDeadlineExceeded;
    if (err.requestOptions.spec.skipNetworkLog &&
        err.type == DioExceptionType.cancel &&
        !deadlineExceeded) {
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
        (!deadlineExceeded &&
            (err.type == DioExceptionType.cancel || (isSilent && isTimeout)))
        ? 'debug'
        : 'warning';

    _logRequest(
      options: err.requestOptions,
      statusCode: err.response?.statusCode,
      level: level,
      responseExtra: err.response?.extra,
      responseHeaders: err.response?.headers,
      error: err,
    );
    handler.next(err);
  }

  void _logRequest({
    required RequestOptions options,
    required int? statusCode,
    required String level,
    Map<String, dynamic>? responseExtra,
    Headers? responseHeaders,
    DioException? error,
  }) {
    final timer = options.extra[_startTimeKey] as Stopwatch?;
    final duration = timer?.elapsedMilliseconds;

    // URL 脱敏：不记录查询参数
    final uri = options.uri;
    final sanitizedUrl = '${uri.scheme}://${uri.host}${uri.path}';

    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'request',
      'event': 'request_complete',
      'traceId': options.extra['traceId'],
      'attemptId': options.extra['attemptId'],
      'coreRequestId': options.extra['coreRequestId'],
      'message': '${options.method} ${uri.path}',
      'method': options.method,
      'url': sanitizedUrl,
      'statusCode': statusCode,
      'duration': duration,
    };
    if (uri.path == '/topics/timings') {
      entry.addAll(_timingsDiagnostics(options));
    }
    // 写请求被拒（403）：记下发出的 cookie 名与响应侧的会话变化，
    // 区分 CSRF/会话失配、运行时 cookie（_rt）被拒与 CF 拦截
    if (statusCode == 403 && options.method.toUpperCase() != 'GET') {
      entry.addAll(_rejectedWriteDiagnostics(options, responseHeaders));
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
    final csrfTrace = options.extra[CsrfSessionTrace.extraKey];
    if (csrfTrace is Map) entry.addAll(csrfTrace.cast<String, dynamic>());
    final adapterName = getRequestAdapterLogName(options);
    if (adapterName != null) {
      entry['networkAdapter'] = adapterName;
    }
    final httpVersion = responseExtra?[HttpClientAdapter.extraKeyHttpVersion]
        ?.toString();
    if (httpVersion != null) {
      entry['httpVersion'] = httpVersion;
    }
    // 网络核心附带的连接信息：区分慢在建连还是慢在服务端
    final connection = responseExtra?[netCoreConnectionExtraKey];
    if (connection is Map) {
      entry['connectionId'] = connection['connectionId'];
      entry['echApplied'] = connection['echApplied'];
      entry['echAccepted'] = connection['echAccepted'];
      entry['connReused'] = connection['reused'];
      entry['tlsResumed'] = connection['tlsResumed'];
      entry['connectMs'] = connection['connectMs'];
      entry['ttfbMs'] = connection['ttfbMs'];
    }
    if (error != null && error.type != DioExceptionType.badResponse) {
      entry['errorType'] = error.error is CallDeadlineExceeded
          ? 'call_deadline'
          : error.type.name;
      if (error.error case CallDeadlineExceeded(:final limit)) {
        entry['callTimeoutMs'] = limit.inMilliseconds;
      }
      final reason = error.error?.toString() ?? error.message;
      if (reason != null && reason.isNotEmpty) {
        entry['error'] = reason;
      }
    }
    LogWriter.instance.write(entry);
  }

  Map<String, dynamic> _rejectedWriteDiagnostics(
    RequestOptions options,
    Headers? responseHeaders,
  ) {
    final cookieHeader =
        options.headers[HttpHeaders.cookieHeader]?.toString() ??
        options.headers['Cookie']?.toString() ??
        '';
    // 只记名字与长度，不落值
    final sentCookies = [
      for (final part in cookieHeader.split(';'))
        if (part.contains('='))
          '${part.split('=').first.trim()}(${part.substring(part.indexOf('=') + 1).length})',
    ];
    final setCookies = responseHeaders?['set-cookie'] ?? const <String>[];
    return {
      'sentCookies': sentCookies.join(','),
      'respSetCookies': [
        for (final cookie in setCookies)
          '${cookie.split('=').first}${RegExp(r'max-age=0|expires=Thu, 01 Jan 1970', caseSensitive: false).hasMatch(cookie) ? '(deleted)' : ''}',
      ].join(','),
      'respCfMitigated': responseHeaders?.value('cf-mitigated'),
      'respLoggedOut': responseHeaders?.value('discourse-logged-out'),
      'respCfRay': responseHeaders?.value('cf-ray'),
    };
  }

  Map<String, dynamic> _timingsDiagnostics(RequestOptions options) {
    final csrfHeader = options.headers['X-CSRF-Token']?.toString();
    final cookieHeader =
        options.headers[HttpHeaders.cookieHeader]?.toString() ??
        options.headers['Cookie']?.toString() ??
        '';
    final sentT = RegExp(r'(?:^|;\s*)_t=([^;]*)')
        .firstMatch(cookieHeader)
        ?.group(1);

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
      'sentHasForumSession': RegExp(r'(?:^|;\s*)_forum_session=')
          .hasMatch(cookieHeader),
    };
  }
}
