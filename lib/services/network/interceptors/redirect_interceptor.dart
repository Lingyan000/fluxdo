import 'dart:async';

import 'package:dio/dio.dart';

import '../../log/log_policy.dart';
import '../core/net_core_http_adapter.dart';
import '../flux_request_spec.dart';

/// 手动跟随重定向，让 Cookie 管理器按目标 URL 重新选取 Cookie。
class RedirectInterceptor extends Interceptor {
  RedirectInterceptor(this._dio);

  final Dio _dio;
  static const hopsKey = 'redirectHops';
  static const _startKey = '_redirectStart';
  static const _countKey = '_redirectCount';
  static const _maxRedirects = 10;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra.putIfAbsent('traceId', LogPolicy.newTraceId);
    options.extra.putIfAbsent('attemptId', LogPolicy.newTraceId);
    options.extra[_startKey] = Stopwatch()..start();
    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final original = response.requestOptions;
    final status = response.statusCode;
    if (original.spec.skipRedirect ||
        !const [301, 302, 303, 307, 308].contains(status)) {
      return handler.next(response);
    }

    var bodyReleased = false;
    try {
      final location = response.headers.value('location');
      if (location == null) return handler.next(response);

      // 小响应体限时读完以保留 H1 连接，其余直接取消，避免阻塞下一跳。
      bodyReleased = true;
      await _discardBody(response);
      final count = original.extra[_countKey] as int? ?? 0;
      final limit = original.maxRedirects < _maxRedirects
          ? original.maxRedirects
          : _maxRedirects;
      if (count >= limit) throw StateError('重定向次数超过上限 $limit');
      final target = original.uri.resolve(location);
      if (!const ['http', 'https'].contains(target.scheme) ||
          target.host.isEmpty ||
          target.userInfo.isNotEmpty) {
        throw StateError('无效的 HTTP 重定向目标');
      }

      final method = original.method.toUpperCase();
      final switchToGet =
          (status == 303 && method != 'HEAD') ||
          ((status == 301 || status == 302) && method == 'POST');
      var data = switchToGet ? null : original.data;
      // 一次性流不能安全重放；不缓存整个上传以换取重试能力。
      if (data is Stream) throw StateError('无法重放流式请求体以跟随重定向');
      if (data is FormData) data = data.clone();

      final crossOrigin = original.uri.origin != target.origin;
      final headers = Map<String, dynamic>.from(original.headers)
        ..removeWhere((key, _) {
          final name = key.toLowerCase();
          return name == 'cookie' ||
              name == 'host' ||
              (switchToGet && _bodyHeaders.contains(name)) ||
              (crossOrigin && _originHeaders.contains(name));
        });
      final connection = response.extra[netCoreConnectionExtraKey];
      final hop = <String, dynamic>{
        'host': original.uri.host,
        'targetHost': target.host,
        'status': status,
        'method': method,
        'elapsedMs':
            (original.extra[_startKey] as Stopwatch?)?.elapsedMilliseconds,
        'attemptId': original.extra['attemptId'],
        'coreRequestId': original.extra['coreRequestId'],
        'httpVersion': response.extra[HttpClientAdapter.extraKeyHttpVersion],
        if (connection is Map)
          for (final key in ['connectionId', 'connectMs', 'ttfbMs', 'reused'])
            if (connection.containsKey(key)) key: connection[key],
      };
      final extra = Map<String, dynamic>.from(original.extra)
        ..remove('attemptId')
        ..remove('coreRequestId')
        ..[FluxRequestKeys.skipScheduler] = true
        ..[_countKey] = count + 1
        ..[hopsKey] = <Map<String, dynamic>>[
          ...?original.extra[hopsKey] as List<Map<String, dynamic>>?,
          hop,
        ];
      // 防止后续请求头拦截器把源站凭据再次注入跨源请求。
      if (crossOrigin) extra[FluxRequestKeys.skipCsrf] = true;
      final next = original.copyWith(
        path: target.toString(),
        queryParameters: {}, // Location 已完整解析，不能重复拼接原查询参数。
        method: switchToGet ? 'GET' : method,
        headers: headers,
        extra: extra,
      )..data = data; // copyWith(data: null) 会保留旧 data，必须显式清空。
      if (switchToGet) {
        next.headers.removeWhere(
          (key, _) => _bodyHeaders.contains(key.toLowerCase()),
        );
        next.onSendProgress = null;
      }
      if (original.cancelToken?.isCancelled ?? false) {
        throw original.cancelToken!.cancelError!;
      }
      handler.resolve(await _dio.fetch<dynamic>(next));
    } catch (error, stack) {
      if (!bodyReleased) await _discardBody(response);
      if (error is DioException) {
        handler.reject(error);
      } else {
        handler.reject(
          DioException(
            requestOptions: original,
            response: response,
            type: DioExceptionType.badResponse,
            error: error,
            stackTrace: stack,
          ),
        );
      }
    }
  }

  static const _bodyHeaders = {
    'content-length',
    'content-type',
    'content-encoding',
    'transfer-encoding',
    'content-language',
    'content-location',
    'digest',
  };
  static const _originHeaders = {
    'authorization',
    'proxy-authorization',
    'x-csrf-token',
    'user-api-key',
    'api-key',
    'api-username',
    'origin',
    'referer',
    'x-requested-with',
    'sec-fetch-site',
    'sec-fetch-mode',
    'sec-fetch-dest',
    'discourse-present',
  };

  static Future<void> _discardBody(Response response) async {
    final body = response.data;
    if (body is! ResponseBody) return;
    const maxDrainBytes = 8 * 1024;
    final length = int.tryParse(
      body.headers[Headers.contentLengthHeader]?.firstOrNull ?? '',
    );
    if (length == null || length < 0 || length > maxDrainBytes) {
      await body.stream
          .listen((_) {}, onError: (Object _, StackTrace _) {})
          .cancel();
      return;
    }
    // 参考 Go/OkHttp 的有限排空：只丢弃小响应，不分配整段缓存。
    // 不信任声明长度；实际字节和等待时间都受限，防止慢/大响应拖住图片。
    final done = Completer<void>();
    var bytes = 0;
    late StreamSubscription<List<int>> subscription;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    subscription = body.stream.listen(
      (chunk) {
        bytes += chunk.length;
        if (bytes > maxDrainBytes) finish();
      },
      onDone: finish,
      onError: (Object _, StackTrace _) => finish(),
    );
    final timer = Timer(const Duration(milliseconds: 100), finish);
    try {
      await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }
}
