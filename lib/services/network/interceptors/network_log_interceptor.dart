import 'package:dio/dio.dart';

import '../../log/log_writer.dart';
import '../adapters/adapter_log_metadata.dart';

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
    if (response.requestOptions.extra['skipNetworkLog'] != true) {
      _logRequest(
        options: response.requestOptions,
        statusCode: response.statusCode,
        level: 'info',
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.extra['skipNetworkLog'] == true &&
        err.type == DioExceptionType.cancel) {
      handler.next(err);
      return;
    }
    final isSilent = err.requestOptions.extra['isSilent'] == true;
    final isTimeout = err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout;

    // cancel: 长轮询频繁 cancel 是正常行为，记录为 debug
    // isSilent + 超时: MessageBus 长轮询超时是正常行为，记录为 debug
    // 其他错误: 记录为 warning
    final level = (err.type == DioExceptionType.cancel || (isSilent && isTimeout))
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
}
