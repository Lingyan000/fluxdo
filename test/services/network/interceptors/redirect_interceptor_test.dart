import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/interceptors/redirect_interceptor.dart';

void main() {
  Dio build(_RecordingAdapter adapter) {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://linux.do',
        validateStatus: (status) => status != null && status < 400,
      ),
    )..httpClientAdapter = adapter;
    dio.interceptors.add(RedirectInterceptor(dio));
    addTearDown(() => dio.close(force: true));
    return dio;
  }

  test('相对 Location 不重复原查询，保留超时、取消及接收回调', () async {
    final adapter = _RecordingAdapter(302, '../final?new=2');
    final dio = build(adapter);
    final token = CancelToken();
    void progress(int _, int _) {}
    final response = await dio.get(
      '/first/image',
      queryParameters: {'old': '1'},
      cancelToken: token,
      onReceiveProgress: progress,
      options: Options(
        receiveTimeout: const Duration(seconds: 7),
        sendTimeout: const Duration(seconds: 9),
        persistentConnection: false,
      ),
    );
    final next = adapter.requests.last;
    expect(next.uri.toString(), 'https://linux.do/final?new=2');
    expect(next.cancelToken, same(token));
    expect(next.receiveTimeout, const Duration(seconds: 7));
    expect(next.sendTimeout, const Duration(seconds: 9));
    expect(next.persistentConnection, false);
    expect(next.onReceiveProgress, same(progress));
    expect(next.extra['traceId'], adapter.requests.first.extra['traceId']);
    expect(
      next.extra['attemptId'],
      isNot(adapter.requests.first.extra['attemptId']),
    );
    final hops =
        response.requestOptions.extra[RedirectInterceptor.hopsKey] as List;
    expect(hops.single['status'], 302);
    expect(hops.single['host'], 'linux.do');
    expect(hops.single.toString(), isNot(contains('old=1')));
  });

  for (final status in [301, 302, 303]) {
    test('$status 将 POST 转 GET 并移除请求体及实体头', () async {
      final adapter = _RecordingAdapter(status, '/final');
      final dio = build(adapter);
      await dio.post(
        '/first',
        data: 'secret body',
        options: Options(
          headers: {
            'Content-Type': 'text/plain',
            'Content-Encoding': 'identity',
          },
        ),
      );
      expect(adapter.requests.last.method, 'GET');
      expect(adapter.bodies.last, isEmpty);
      expect(
        adapter.requests.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('content-type')),
      );
    });
  }

  test('303 保留 HEAD', () async {
    final adapter = _RecordingAdapter(303, '/final');
    await build(adapter).head('/first');
    expect(adapter.requests.last.method, 'HEAD');
  });

  for (final status in [307, 308]) {
    test('$status 完整保留可重放的 POST 内容', () async {
      final adapter = _RecordingAdapter(status, '/final');
      await build(adapter).post('/first', data: 'original body');
      expect(adapter.requests.last.method, 'POST');
      expect(adapter.bodies.last, adapter.bodies.first);
      expect(adapter.bodies.last, isNotEmpty);
    });
  }

  test('307 重建 FormData，上传字段和文件均不丢失', () async {
    final adapter = _RecordingAdapter(307, '/final');
    await build(adapter).post(
      '/first',
      data: FormData.fromMap({
        'title': 'hello',
        'file': MultipartFile.fromBytes([0, 1, 255], filename: 'a.bin'),
      }),
    );
    final last = String.fromCharCodes(adapter.bodies.last);
    expect(last, contains('hello'));
    expect(last, contains('a.bin'));
    expect(last, contains(String.fromCharCodes([0, 1, 255])));
  });

  test('307 不重放一次性上传流，也不发送空 POST', () async {
    final adapter = _RecordingAdapter(307, '/final');
    await expectLater(
      build(adapter).post('/first', data: Stream.value([1, 2, 3])),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('跨源移除凭据并禁止 CSRF 重新注入，同源保留授权', () async {
    for (final target in ['/final', 'https://cdn.example.test/final']) {
      final adapter = _RecordingAdapter(302, target);
      await build(adapter).get(
        '/first',
        options: Options(
          headers: {
            'Authorization': 'Bearer secret',
            'X-CSRF-Token': 'csrf',
            'User-Api-Key': 'api',
            'cOoKiE': 'session=one',
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );
      final next = adapter.requests.last;
      final headers = {
        for (final entry in next.headers.entries)
          entry.key.toLowerCase(): entry.value,
      };
      expect(headers, isNot(contains('cookie')));
      if (target.startsWith('https')) {
        expect(headers.keys, isNot(contains('authorization')));
        expect(headers.keys, isNot(contains('x-csrf-token')));
        expect(headers.keys, isNot(contains('user-api-key')));
        expect(headers.keys, isNot(contains('x-requested-with')));
        expect(next.extra['skipCsrf'], true);
      } else {
        expect(headers['authorization'], 'Bearer secret');
      }
    }
  });

  test('跳转后的在途请求可由原 CancelToken 取消', () async {
    final adapter = _RecordingAdapter(302, '/final')
      ..waitForCancellation = true;
    final token = CancelToken();
    final pending = build(adapter).get('/first', cancelToken: token);
    final check = expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await adapter.finalStarted.future;
    token.cancel('离开页面');
    await check;
  });

  test('跳转前取消未消费的响应流，不等大响应体读完', () async {
    final adapter = _RecordingAdapter(302, '/final')..streamRedirect = true;
    final response = await build(adapter).get<ResponseBody>(
      '/first',
      options: Options(responseType: ResponseType.stream),
    );
    expect(adapter.redirectClosed, 1);
    expect(adapter.redirectCancelled, 1);
    await response.data!.stream.drain<void>();
  });

  test('小重定向响应停滞时限时释放，不等待整个接收超时', () async {
    final adapter = _RecordingAdapter(302, '/final')
      ..streamRedirect = true
      ..declaredLength = 2;
    final response = await build(adapter)
        .get<ResponseBody>(
          '/first',
          options: Options(responseType: ResponseType.stream),
        )
        .timeout(const Duration(seconds: 1));
    expect(adapter.redirectClosed, 1);
    await response.data!.stream.drain<void>();
  });

  test('声明小响应但实际超出预算时停止排空', () async {
    final adapter = _RecordingAdapter(302, '/final')
      ..streamRedirect = true
      ..declaredLength = 2
      ..redirectPayload = List.filled(8193, 1);
    final response = await build(adapter).get<ResponseBody>(
      '/first',
      options: Options(responseType: ResponseType.stream),
    );
    expect(adapter.redirectClosed, 1);
    expect(adapter.redirectCancelled, 1);
    await response.data!.stream.drain<void>();
  });

  test('拒绝非 HTTP 目标并遵守调用方跳转上限', () async {
    final adapter = _RecordingAdapter(302, 'file:///tmp/test');
    await expectLater(
      build(adapter).get('/first'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
    final limited = _RecordingAdapter(302, '/final');
    await expectLater(
      build(limited).get('/first', options: Options(maxRedirects: 0)),
      throwsA(isA<DioException>()),
    );
    expect(limited.requests, hasLength(1));
  });

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

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.status, this.location);
  final int status;
  final String location;
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];
  final finalStarted = Completer<void>();
  bool waitForCancellation = false;
  bool streamRedirect = false;
  int? declaredLength;
  List<int>? redirectPayload;
  int redirectClosed = 0;
  int redirectCancelled = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(await requestStream?.expand((bytes) => bytes).toList() ?? []);
    if (requests.length == 1) {
      if (streamRedirect) {
        late StreamController<Uint8List> controller;
        controller = StreamController<Uint8List>(
          onListen: () {
            if (redirectPayload != null) {
              controller.add(Uint8List.fromList(redirectPayload!));
            }
          },
          onCancel: () {
            redirectCancelled++;
          },
        );
        return ResponseBody(
          controller.stream,
          status,
          headers: {
            'location': [location],
            if (declaredLength != null) 'content-length': ['$declaredLength'],
          },
          onClose: () {
            redirectClosed++;
            controller.close();
          },
        );
      }
      return ResponseBody.fromString(
        '',
        status,
        headers: {
          'location': [location],
        },
      );
    }
    finalStarted.complete();
    if (waitForCancellation) {
      await cancelFuture;
      throw options.cancelToken!.cancelError!;
    }
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
