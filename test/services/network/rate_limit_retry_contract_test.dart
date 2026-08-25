import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';

/// 「限流重试」跨层契约。
///
/// 上传(`_uploads.dart` 的 uploadFile / lookupUrls)用手写 for 循环做限流
/// 重试,判据是 `e.error is RateLimitException`、等待时长取
/// `retryAfterSeconds`。这条契约横跨拦截器与业务层,没有任何一侧的单测能
/// 单独锁住它——本文件用一个与 uploadFile 同构的最小重试循环把它钉住。
///
/// 若 ErrorInterceptor 改变 429 的产出形态(异常类型、是否携带 response、
/// retryAfter 解析口径),这里会立刻红灯。
void main() {
  // showErrorToast 为 true 的分支会调 ToastService(它在无 overlay 时安全早退),
  // 但需要 binding 已初始化才能访问 navigatorKey。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('429 → RateLimitException 的可消费形态', () {
    test('业务层能按 e.error 类型判定重试，并读到 Retry-After 秒数', () async {
      final adapter = _ScriptedAdapter([
        _Reply.rateLimited(retryAfterHeader: '3'),
        _Reply.rateLimited(retryAfterHeader: '3'),
        _Reply.ok('{"short_url":"upload://abc"}'),
      ]);
      final dio = _buildDio(adapter);

      final waits = <int>[];
      final result = await _retryLikeUpload(
        dio,
        maxRetries: 3,
        defaultWaitSeconds: 10,
        onWait: waits.add,
      );

      expect(result, contains('upload://abc'));
      // 两次限流各等待 3 秒(来自 Retry-After),第三次成功
      expect(waits, [3, 3]);
      expect(adapter.callCount, 3);
    });

    test('响应未给出 Retry-After 时业务层回落到自己的缺省等待', () async {
      final adapter = _ScriptedAdapter([
        _Reply.rateLimited(),
        _Reply.ok('{"short_url":"upload://abc"}'),
      ]);
      final dio = _buildDio(adapter);

      final waits = <int>[];
      await _retryLikeUpload(
        dio,
        maxRetries: 3,
        defaultWaitSeconds: 10,
        onWait: waits.add,
      );

      expect(waits, [10]);
    });

    test('Discourse 中文限流文案里的等待秒数可被解析出来', () async {
      final adapter = _ScriptedAdapter([
        _Reply.rateLimited(body: '{"errors":["请等待 42 秒后再试"]}'),
        _Reply.ok('{}'),
      ]);
      final dio = _buildDio(adapter);

      final waits = <int>[];
      await _retryLikeUpload(
        dio,
        maxRetries: 3,
        defaultWaitSeconds: 10,
        onWait: waits.add,
      );

      expect(waits, [42]);
    });

    test('重试次数用尽后抛出，且异常仍带 429 response 供业务层取服务端文案', () async {
      final adapter = _ScriptedAdapter([
        _Reply.rateLimited(body: '{"errors":["太快了"]}'),
        _Reply.rateLimited(body: '{"errors":["太快了"]}'),
      ]);
      final dio = _buildDio(adapter);

      Object? thrown;
      try {
        await _retryLikeUpload(
          dio,
          maxRetries: 1, // 允许 1 次重试 → 共 2 次尝试
          defaultWaitSeconds: 0,
          onWait: (_) {},
        );
      } catch (e) {
        thrown = e;
      }

      expect(adapter.callCount, 2);
      expect(thrown, isA<DioException>());
      final err = thrown as DioException;
      expect(err.error, isA<RateLimitException>());
      // 结果保真:业务层(如打赏)靠 response.data 提取服务端报错文案
      expect(err.response?.statusCode, 429);
      expect(err.response?.data.toString(), contains('太快了'));
    });
  });

  group('非限流错误不参与限流重试', () {
    test('413 直接终止，不重试', () async {
      final adapter = _ScriptedAdapter([_Reply(413, '{"errors":["文件过大"]}')]);
      final dio = _buildDio(adapter);

      Object? thrown;
      try {
        await _retryLikeUpload(
          dio,
          maxRetries: 3,
          defaultWaitSeconds: 0,
          onWait: (_) {},
        );
      } catch (e) {
        thrown = e;
      }

      expect(adapter.callCount, 1);
      expect((thrown as DioException).response?.statusCode, 413);
      expect(thrown.error, isNot(isA<RateLimitException>()));
    });

    test('503 转 ServerException，同样不进限流重试分支', () async {
      final adapter = _ScriptedAdapter([_Reply(503, 'unavailable')]);
      final dio = _buildDio(adapter);

      Object? thrown;
      try {
        await _retryLikeUpload(
          dio,
          maxRetries: 3,
          defaultWaitSeconds: 0,
          onWait: (_) {},
        );
      } catch (e) {
        thrown = e;
      }

      expect(adapter.callCount, 1);
      final err = thrown as DioException;
      expect(err.error, isA<ServerException>());
      expect(err.response?.statusCode, 503);
    });
  });

  test('仅最后一次尝试允许弹 toast（showErrorToast 随尝试序号变化）', () async {
    final adapter = _ScriptedAdapter([
      _Reply.rateLimited(),
      _Reply.rateLimited(),
      _Reply.rateLimited(),
    ]);
    final dio = _buildDio(adapter);

    try {
      await _retryLikeUpload(
        dio,
        maxRetries: 2, // 共 3 次尝试
        defaultWaitSeconds: 0,
        onWait: (_) {},
      );
    } catch (_) {
      // 预期最终失败
    }

    // 前两次静默、末次才允许提示 —— 与 uploadFile 的
    // `'showErrorToast': attempt >= maxRetries` 同构
    expect(adapter.showErrorToastFlags, [false, false, true]);
  });
}

/// 与 `_uploads.dart` 的 uploadFile 同构的最小重试循环。
///
/// 只保留与网络层契约相关的部分:按 `e.error is RateLimitException` 判定
/// 重试、等待 `retryAfterSeconds ?? 缺省`、`showErrorToast` 仅末次为 true。
Future<String> _retryLikeUpload(
  Dio dio, {
  required int maxRetries,
  required int defaultWaitSeconds,
  required void Function(int seconds) onWait,
}) async {
  for (int attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      final response = await dio.post<dynamic>(
        '/uploads.json',
        options: Options(extra: {'showErrorToast': attempt >= maxRetries}),
      );
      return response.data.toString();
    } on DioException catch (e) {
      final innerError = e.error;
      if (innerError is RateLimitException && attempt < maxRetries) {
        onWait(innerError.retryAfterSeconds ?? defaultWaitSeconds);
        continue;
      }
      rethrow;
    }
  }
  throw StateError('unreachable');
}

Dio _buildDio(_ScriptedAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = adapter;
  dio.interceptors.add(ErrorInterceptor());
  return dio;
}

class _Reply {
  _Reply(this.statusCode, this.body, [this.headers = const {}]);

  factory _Reply.ok(String body) => _Reply(200, body, {
    Headers.contentTypeHeader: ['application/json'],
  });

  factory _Reply.rateLimited({String? retryAfterHeader, String? body}) =>
      _Reply(429, body ?? '{"errors":["rate limited"]}', {
        Headers.contentTypeHeader: ['application/json'],
        if (retryAfterHeader != null) 'retry-after': [retryAfterHeader],
      });

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
}

/// 按脚本依次返回预设响应，并记录每次请求的 showErrorToast 标记。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._replies);

  final List<_Reply> _replies;
  int callCount = 0;
  final List<bool> showErrorToastFlags = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    showErrorToastFlags.add(options.extra['showErrorToast'] == true);
    final reply = _replies[callCount.clamp(0, _replies.length - 1)];
    callCount++;
    return ResponseBody.fromString(
      reply.body,
      reply.statusCode,
      headers: reply.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
