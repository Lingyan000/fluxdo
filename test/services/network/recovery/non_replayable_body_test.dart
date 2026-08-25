import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/recovery/policies.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';

/// 恢复层不得重放不可重放的请求体。
///
/// dio 的 FormData 是一次性的:`finalize()` 之后二次使用抛
/// `StateError('The FormData has already been finalized')`。上传正是这个形态。
///
/// 这条护栏是实测出来的:恢复层刚落地时 RateLimitPolicy 不看请求方法也不看
/// 请求体形态,上传撞 429 → 重放 → StateError,把一个**本可恢复的限流**变成
/// 硬失败,而且错误类型完全丢失(调用方拿到 StateError 而不是
/// RateLimitException,按类型判定的重试逻辑直接失效)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FormData 上传的 429 不被重放,且错误类型保真', () async {
    final adapter = _ScriptedAdapter(
      firstReply: _Reply.rateLimited(retryAfter: '1'),
    );
    final dio = _buildDio(adapter);

    DioException? caught;
    try {
      await dio.post<dynamic>(
        '/uploads.json',
        data: FormData.fromMap({'upload_type': 'composer', 'file': 'dummy'}),
        // 与 _uploads.dart 同形:非末轮尝试不弹 toast
        options: Options(extra: const {'showErrorToast': false}),
      );
    } on DioException catch (e) {
      caught = e;
    }

    // 只发一次:没有重放
    expect(adapter.callCount, 1);
    // 错误类型保真:调用方(_uploads.dart)靠 `e.error is RateLimitException`
    // 判定要不要重试。若 FormData 被重放,这里会变成 StateError,判定失效。
    expect(caught!.error, isA<RateLimitException>());
    expect(caught.response?.statusCode, 429);
    expect(
      (caught.error as RateLimitException).retryAfterSeconds,
      1,
      reason: '调用方要读它决定等多久',
    );
  });

  test('流式请求体同样不被重放', () async {
    final adapter = _ScriptedAdapter(
      firstReply: _Reply.rateLimited(retryAfter: '1'),
    );
    final dio = _buildDio(adapter);

    try {
      await dio.post<dynamic>(
        '/uploads.json',
        data: Stream<List<int>>.fromIterable([
          [1, 2, 3],
        ]),
        options: Options(
          headers: {Headers.contentLengthHeader: 3},
          extra: const {'showErrorToast': false},
        ),
      );
    } on DioException catch (_) {}

    expect(adapter.callCount, 1);
  });

  test('对照:普通 JSON 体的 429 仍然会被重放', () async {
    final adapter = _ScriptedAdapter(
      firstReply: _Reply.rateLimited(retryAfter: '1'),
    );
    final dio = _buildDio(adapter);

    final response = await dio.post<dynamic>(
      '/posts.json',
      data: const {'raw': 'hello'},
    );

    // 可重放的请求体照常享受限流恢复
    expect(adapter.callCount, 2);
    expect(response.statusCode, 200);
  });
}

Dio _buildDio(_ScriptedAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = adapter;
  // 与生产链路同序:恢复层先看到失败,ErrorInterceptor 随后做类型化包装
  dio.interceptors.add(
    RecoveryCoordinator(
      dio: dio,
      policies: [const RateLimitPolicy(maxWaitSeconds: 30)],
    ),
  );
  dio.interceptors.add(ErrorInterceptor());
  return dio;
}

class _Reply {
  _Reply(this.statusCode, this.body, [this.headers = const {}]);

  factory _Reply.rateLimited({required String retryAfter}) => _Reply(
    429,
    '{"errors":["rate limited"]}',
    {'retry-after': [retryAfter]},
  );

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({required this.firstReply});

  final _Reply firstReply;
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    // 消费请求流,复现真实传输(FormData 由此 finalize)
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    final reply = callCount == 1
        ? firstReply
        : _Reply(200, '{"short_url":"upload://ok"}');
    return ResponseBody.fromString(
      reply.body,
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
        ...reply.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
