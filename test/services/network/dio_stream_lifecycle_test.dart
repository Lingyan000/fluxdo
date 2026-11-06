import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _StreamAdapter adapter;
  late Dio dio;
  setUp(() {
    adapter = _StreamAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });
  tearDown(() => dio.close(force: true));

  Future<ResponseBody> open({
    CancelToken? token,
    Duration? timeout,
    ProgressCallback? onProgress,
  }) async {
    final response = await dio.get<ResponseBody>(
      'https://example.test/image',
      cancelToken: token,
      onReceiveProgress: onProgress,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: timeout,
      ),
    );
    return response.data!;
  }

  test('公开 Dio 流接口在消费前不订阅源、不启动接收计时', () async {
    final body = await open(timeout: const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(adapter.listenCount, 0);
    final bytes = await body.stream.expand((chunk) => chunk).toList();
    expect(bytes, [1, 2, 3]);
  });

  test('公开 Dio 流取消传递到源并关闭响应', () async {
    final body = await open();
    final sub = body.stream.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await sub.cancel();
    expect(adapter.cancelCount, 1);
    expect(adapter.closeCount, 1);
  });

  test('暂停消费不消耗接收时限，恢复后字节完整', () async {
    final body = await open(timeout: const Duration(milliseconds: 40));
    final iterator = StreamIterator(body.stream);
    final bytes = <int>[];
    while (await iterator.moveNext()) {
      bytes.addAll(iterator.current);
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
    expect(bytes, [1, 2, 3]);
  });

  test('上游真正停滞仍触发接收超时并释放源', () async {
    adapter.stall = true;
    final body = await open(timeout: const Duration(milliseconds: 40));
    await expectLater(
      body.stream.drain<void>(),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(adapter.cancelCount, 1);
    expect(adapter.closeCount, 1);
  });

  test('未订阅时取消令牌关闭响应，后续订阅读到取消错误', () async {
    final token = CancelToken();
    final body = await open(token: token);
    token.cancel('离开页面');
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      body.stream.drain<void>(),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(adapter.listenCount, 0);
    expect(adapter.closeCount, 1);
  });

  test('进度回调抛错时释放源并交给消费者处理', () async {
    final body = await open(onProgress: (_, _) => throw StateError('consumer'));
    await expectLater(body.stream.drain<void>(), throwsA(isA<StateError>()));
    expect(adapter.cancelCount, 1);
    expect(adapter.closeCount, 1);
  });

  test('正常结束后取消复用令牌不再次关闭已完成响应', () async {
    final token = CancelToken();
    final body = await open(token: token);
    await body.stream.drain<void>();
    token.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.closeCount, 0);
  });
}

class _StreamAdapter implements HttpClientAdapter {
  int listenCount = 0;
  int cancelCount = 0;
  int closeCount = 0;
  bool stall = false;
  Timer? timer;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late StreamController<Uint8List> source;
    var count = 0;
    void pump() {
      timer = Timer.periodic(const Duration(milliseconds: 15), (_) {
        if (stall) return;
        source.add(Uint8List.fromList([++count]));
        if (count == 3) {
          timer?.cancel();
          source.close();
        }
      });
    }

    source = StreamController<Uint8List>(
      onListen: () {
        listenCount++;
        pump();
      },
      onPause: () => timer?.cancel(),
      onResume: pump,
      onCancel: () {
        cancelCount++;
        timer?.cancel();
      },
    );
    return ResponseBody(
      source.stream,
      200,
      onClose: () {
        closeCount++;
        timer?.cancel();
      },
    );
  }

  @override
  void close({bool force = false}) => timer?.cancel();
}
