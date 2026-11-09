import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/recovery/policies.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';

void main() {
  test('总时限跨越多次尝试，停止底层传输且不取消调用方共享 token', () async {
    final adapter = _Adapter((options, cancel) async {
      await Future<void>.delayed(const Duration(milliseconds: 55));
      throw DioException.connectionTimeout(
        requestOptions: options,
        timeout: const Duration(milliseconds: 55),
      );
    });
    final dio = _client(adapter, const Duration(milliseconds: 140));
    final parent = CancelToken();
    await expectLater(
      dio.get<dynamic>('https://example.test', cancelToken: parent),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    expect(adapter.calls, inInclusiveRange(2, 3));
    expect(parent.isCancelled, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(adapter.calls, lessThan(4));
    dio.close(force: true);
  });

  test('截止包含拦截器排队，过期请求不进入适配器', () async {
    final adapter = _Adapter(
      (_, _) async => ResponseBody.fromString('{}', 200),
    );
    final dio = _client(adapter, const Duration(milliseconds: 30));
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await Future<void>.delayed(const Duration(milliseconds: 70));
          handler.next(options);
        },
      ),
    );
    await expectLater(
      dio.get<dynamic>('https://example.test'),
      throwsA(isA<DioException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(adapter.calls, 0);
    dio.close(force: true);
  });

  test('取消退避立即结束，不等下一次重试', () async {
    final adapter = _Adapter((_, _) async => ResponseBody.fromString('', 503));
    final dio = DeadlineDio(BaseOptions(), const Duration(seconds: 10))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      RecoveryCoordinator(dio: dio, policies: const [TransientRetryPolicy()]),
    );
    final token = CancelToken();
    final request = dio.get<dynamic>(
      'https://example.test',
      cancelToken: token,
    );
    final assertion = expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    token.cancel();
    await assertion.timeout(const Duration(milliseconds: 300));
    expect(adapter.calls, 1);
    dio.close(force: true);
  });

  test('重定向的递归 fetch 不重新开始总时限', () async {
    final adapter = _Adapter((options, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return ResponseBody.fromString(
        '',
        options.uri.path == '/one' ? 302 : 200,
      );
    });
    final dio = DeadlineDio(
      BaseOptions(validateStatus: (_) => true),
      const Duration(milliseconds: 95),
    )..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          if (response.statusCode != 302) return handler.next(response);
          try {
            handler.resolve(
              await dio.fetch<dynamic>(
                response.requestOptions.copyWith(path: '/two'),
              ),
            );
          } on DioException catch (error) {
            handler.reject(error);
          }
        },
      ),
    );
    await expectLater(
      dio.get<dynamic>('https://example.test/one'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    expect(adapter.calls, 2);
    dio.close(force: true);
  });

  test('流式响应显式预算持续至响应体结束，并取消底层读取', () async {
    final body = StreamController<Uint8List>();
    final adapter = _Adapter((options, cancel) async {
      cancel?.then((_) {
        body.addError(
          DioException.requestCancelled(
            requestOptions: options,
            reason: 'test cancellation',
          ),
        );
        body.close();
      });
      return ResponseBody(body.stream, 200);
    });
    final dio = _client(adapter, const Duration(milliseconds: 10));
    final response = await dio.get<ResponseBody>(
      'https://example.test',
      options: Options(
        responseType: ResponseType.stream,
        extra: {FluxRequestKeys.callTimeoutMillis: 60},
      ),
    );
    await expectLater(
      response.data!.stream.drain<void>(),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    dio.close(force: true);
  });

  test('普通预算不套写操作、长轮询；显式 0 关闭读取预算', () async {
    final adapter = _Adapter((_, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      return ResponseBody.fromString('{}', 200);
    });
    final dio = _client(adapter, const Duration(milliseconds: 10));
    expect((await dio.post<dynamic>('https://example.test')).statusCode, 200);
    expect(
      (await dio.get<dynamic>(
        'https://example.test',
        options: Options(extra: {'noRecovery': true}),
      )).statusCode,
      200,
    );
    expect(
      (await dio.get<dynamic>(
        'https://example.test',
        options: Options(extra: {FluxRequestKeys.callTimeoutMillis: 0}),
      )).statusCode,
      200,
    );
    dio.close(force: true);
  });

  test('成功后释放计时器，不晚到取消传输', () async {
    var cancelled = false;
    final adapter = _Adapter((_, cancel) async {
      cancel?.then((_) => cancelled = true);
      return ResponseBody.fromString('{}', 200);
    });
    final dio = _client(adapter, const Duration(milliseconds: 30));
    await dio.get<dynamic>('https://example.test');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(cancelled, isFalse);
    dio.close(force: true);
  });

  test('提前取消响应体订阅会取消适配器，但不取消调用方 token', () async {
    final body = StreamController<Uint8List>();
    final stopped = Completer<void>();
    final adapter = _Adapter((_, cancel) async {
      cancel?.then((_) {
        if (!stopped.isCompleted) stopped.complete();
        body.close();
      });
      return ResponseBody(body.stream, 200);
    });
    final parent = CancelToken();
    final dio = _client(adapter, const Duration(seconds: 10));
    final response = await dio.get<ResponseBody>(
      'https://example.test',
      cancelToken: parent,
      options: Options(
        responseType: ResponseType.stream,
        extra: {FluxRequestKeys.callTimeoutMillis: 10000},
      ),
    );
    final first = Completer<void>();
    final subscription = response.data!.stream.listen((_) => first.complete());
    body.add(Uint8List.fromList([1]));
    await first.future;
    await subscription.cancel();
    await stopped.future.timeout(const Duration(seconds: 1));
    expect(parent.isCancelled, isFalse);
    dio.close(force: true);
  });

  test('持续有数据到达也不能延长整次响应体时限', () async {
    final body = StreamController<Uint8List>();
    final stopped = Completer<void>();
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      body.add(Uint8List.fromList([1]));
    });
    final adapter = _Adapter((_, cancel) async {
      cancel?.then((_) {
        ticker.cancel();
        body.close();
        stopped.complete();
      });
      return ResponseBody(body.stream, 200);
    });
    final dio = _client(adapter, const Duration(milliseconds: 80));
    await expectLater(
      dio.get<List<int>>(
        'https://example.test',
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(milliseconds: 60),
        ),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    await stopped.future.timeout(const Duration(seconds: 1));
    expect(ticker.isActive, isFalse);
    dio.close(force: true);
  });

  test('共享父 token 的另一个请求不受本请求截止影响', () async {
    final adapter = _Adapter((options, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return ResponseBody.fromString('{}', 200);
    });
    final dio = _client(adapter, const Duration(milliseconds: 30));
    final parent = CancelToken();
    final short = expectLater(
      dio.get<dynamic>('https://example.test/short', cancelToken: parent),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    final other = dio.get<dynamic>(
      'https://example.test/other',
      cancelToken: parent,
      options: Options(extra: {FluxRequestKeys.callTimeoutMillis: 500}),
    );
    await short;
    expect((await other).statusCode, 200);
    expect(parent.isCancelled, isFalse);
    dio.close(force: true);
  });
}

DeadlineDio _client(_Adapter adapter, Duration timeout) {
  final dio = DeadlineDio(BaseOptions(), timeout)..httpClientAdapter = adapter;
  dio.interceptors.add(
    RecoveryCoordinator(
      dio: dio,
      policies: const [
        TransientRetryPolicy(delays: [Duration.zero]),
      ],
    ),
  );
  return dio;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, Future<void>?) respond;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls++;
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
