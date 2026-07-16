import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/interceptors/redirect_interceptor.dart';

void main() {
  test('内部重定向绕过调度器并保留原请求计数标记', () async {
    final adapter = _RedirectOnceAdapter();
    final requestExtras = <Map<String, dynamic>>[];
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://linux.do',
        validateStatus: (status) => status != null && status < 400,
      ),
    )..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestExtras.add(Map<String, dynamic>.from(options.extra));
          handler.next(options);
        },
      ),
    );
    dio.interceptors.add(RedirectInterceptor(dio));

    final response = await dio.get(
      '/',
      options: Options(extra: {'_schedulerCounted': true}),
    );

    expect(response.statusCode, 200);
    expect(adapter.fetchCount, 2);
    expect(requestExtras, hasLength(2));
    expect(requestExtras.last['skipScheduler'], isTrue);
    expect(requestExtras.last['_redirectCount'], 1);
    expect(requestExtras.last['_schedulerCounted'], isTrue);
  });
}

class _RedirectOnceAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    if (fetchCount == 1) {
      return ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': ['https://linux.do/final'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
