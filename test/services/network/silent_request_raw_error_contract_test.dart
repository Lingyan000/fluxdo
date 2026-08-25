import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';

/// MessageBus 长轮询的「原始 429」契约。
///
/// poll 循环靠这两行读退避时长(`message_bus_service.dart`):
/// ```dart
/// } else if (e.response?.statusCode == 429) {
///   final retryAfter = int.tryParse(
///       e.response?.headers.value('Retry-After') ?? '');
/// ```
/// 成立的前提有两条,都在网络层:
/// 1. 请求带 `isSilent: true` → ErrorInterceptor 直接放行,不弹 toast、
///    不把错误加工成类型化异常;
/// 2. 无论是否加工,`err.response` 必须存活(否则 statusCode 与响应头全丢)。
///
/// 这两条以前没有任何测试保护:第 2 条曾因 ErrorInterceptor 用 throw 抛
/// 类型化异常而被破坏(网络日志里限流请求 statusCode 恒为 null)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isSilent 的 429 保持原始 DioException：不转类型化异常，response 完整', () async {
    final dio = _buildDio(retryAfter: '30');

    DioException? caught;
    try {
      await dio.post<dynamic>(
        '/message-bus/abc/poll',
        options: Options(extra: {'isSilent': true}),
      );
    } on DioException catch (e) {
      caught = e;
    }

    expect(caught, isNotNull);
    // 静默请求不被加工成 RateLimitException
    expect(caught!.error, isNot(isA<RateLimitException>()));
    // poll 循环读取的两个字段都在
    expect(caught.response?.statusCode, 429);
    expect(caught.response?.headers.value('Retry-After'), '30');
  });

  test('非静默的 429 会被加工成类型化异常，但 response 同样保留', () async {
    final dio = _buildDio(retryAfter: '30');

    DioException? caught;
    try {
      // 不带 isSilent：走 ErrorInterceptor 的加工分支
      await dio.get<dynamic>('/latest.json');
    } on DioException catch (e) {
      caught = e;
    }

    expect(caught!.error, isA<RateLimitException>());
    // 结果保真：即使被加工，statusCode 与响应头仍可读
    expect(caught.response?.statusCode, 429);
    expect(caught.response?.headers.value('Retry-After'), '30');
  });

  test('缺少 Retry-After 头时读到 null，由调用方回落到自己的下限', () async {
    final dio = _buildDio();

    DioException? caught;
    try {
      await dio.post<dynamic>(
        '/message-bus/abc/poll',
        options: Options(extra: {'isSilent': true}),
      );
    } on DioException catch (e) {
      caught = e;
    }

    expect(caught!.response?.statusCode, 429);
    final retryAfter = int.tryParse(
      caught.response?.headers.value('Retry-After') ?? '',
    );
    expect(retryAfter, isNull);
  });
}

Dio _buildDio({String? retryAfter}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = _RateLimitedAdapter(retryAfter);
  dio.interceptors.add(ErrorInterceptor());
  return dio;
}

class _RateLimitedAdapter implements HttpClientAdapter {
  _RateLimitedAdapter(this.retryAfter);

  final String? retryAfter;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"errors":["rate limited"]}',
      429,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (retryAfter != null) 'Retry-After': [retryAfter!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
