import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';

/// ErrorInterceptor 的「结果保真」契约:
/// 把 429/5xx 转成类型化异常时,必须保留原始 response,
/// 否则下游拦截器(CF 验证/网络日志)与调用方只能看到 statusCode=null。
void main() {
  test('429 转 RateLimitException 后下游与调用方仍可见原始 response', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 429,
      body: '{"errors":["请等待 7 秒"]}',
      headers: {
        'retry-after': ['7'],
        Headers.contentTypeHeader: ['application/json'],
      },
      downstream: downstream,
    );

    Object? callerError;
    int? callerStatus;
    try {
      await dio.get('/latest.json');
    } on DioException catch (e) {
      callerError = e.error;
      callerStatus = e.response?.statusCode;
    }

    // 下游拦截器(注册在 ErrorInterceptor 之后)看得到状态码与响应体
    expect(downstream.seenStatusCode, 429);
    expect(downstream.seenError, isA<RateLimitException>());

    // 调用方拿到类型化异常,且 response 未丢失
    expect(callerStatus, 429);
    expect(callerError, isA<RateLimitException>());
    final rateLimit = callerError as RateLimitException;
    expect(rateLimit.retryAfterSeconds, 7);
    // 异常自身也挂着 response,供业务层提取服务端文案
    expect(rateLimit.response?.statusCode, 429);
  });

  test('503 转 ServerException 后仍可见原始 response', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 503,
      body: 'service unavailable',
      headers: const {},
      downstream: downstream,
    );

    Object? callerError;
    int? callerStatus;
    try {
      await dio.get('/latest.json');
    } on DioException catch (e) {
      callerError = e.error;
      callerStatus = e.response?.statusCode;
    }

    expect(downstream.seenStatusCode, 503);
    expect(callerStatus, 503);
    expect(callerError, isA<ServerException>());
    expect((callerError as ServerException).statusCode, 503);
  });
}

Dio _buildDio({
  required int statusCode,
  required String body,
  required Map<String, List<String>> headers,
  required _CaptureInterceptor downstream,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = _FixedStatusAdapter(statusCode, body, headers);
  // 静默请求会在 ErrorInterceptor 早退,这里用默认(非静默)GET,
  // 且 GET 默认不弹 toast,避免测试环境缺少 l10n/Overlay。
  dio.interceptors.add(ErrorInterceptor());
  dio.interceptors.add(downstream);
  return dio;
}

class _CaptureInterceptor extends Interceptor {
  int? seenStatusCode;
  Object? seenError;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    seenStatusCode = err.response?.statusCode;
    seenError = err.error;
    handler.next(err);
  }
}

class _FixedStatusAdapter implements HttpClientAdapter {
  _FixedStatusAdapter(this.statusCode, this.body, this.headers);

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(body, statusCode, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}
