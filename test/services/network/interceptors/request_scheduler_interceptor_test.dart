import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/interceptors/request_scheduler_interceptor.dart';
import 'package:fluxdo/services/network/request_scheduler_config.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';

class _Adapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('速率窗口内到期的请求保留截止原因，且窗口打开后不再发送', () async {
    final oldMax = RequestSchedulerConfig.maxPerWindow;
    final oldSeconds = RequestSchedulerConfig.windowSeconds;
    RequestSchedulerConfig.maxPerWindow = 1;
    RequestSchedulerConfig.windowSeconds = 1;
    final adapter = _Adapter();
    final dio =
        DeadlineDio(
            BaseOptions(baseUrl: 'https://scheduler-deadline.test'),
            const Duration(milliseconds: 100),
          )
          ..httpClientAdapter = adapter
          ..interceptors.add(RequestSchedulerInterceptor());
    addTearDown(() {
      dio.close(force: true);
      RequestSchedulerConfig.maxPerWindow = oldMax;
      RequestSchedulerConfig.windowSeconds = oldSeconds;
    });
    await dio.get<dynamic>('/first');
    await expectLater(
      dio.get<dynamic>('/expired'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<CallDeadlineExceeded>(),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(adapter.calls, 1);
    expect((await dio.get<dynamic>('/next')).statusCode, 200);
    expect(adapter.calls, 2);
  });

  test('并发为零但速率窗口已满时，排队请求在窗口到期后自动发出', () async {
    final oldConcurrent = RequestSchedulerConfig.maxConcurrent;
    final oldMax = RequestSchedulerConfig.maxPerWindow;
    final oldSeconds = RequestSchedulerConfig.windowSeconds;
    RequestSchedulerConfig.maxConcurrent = 3;
    RequestSchedulerConfig.maxPerWindow = 1;
    RequestSchedulerConfig.windowSeconds = 1;
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://scheduler-idle.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(RequestSchedulerInterceptor());
    addTearDown(() {
      dio.close(force: true);
      RequestSchedulerConfig.maxConcurrent = oldConcurrent;
      RequestSchedulerConfig.maxPerWindow = oldMax;
      RequestSchedulerConfig.windowSeconds = oldSeconds;
    });

    // 首个请求已经完成：没有在途请求再触发 _release。
    await dio.get('/chat/api/channels/2/messages');
    expect(adapter.calls, 1);
    final second = dio.get('/chat/api/channels/2/messages');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(adapter.calls, 1);
    final response = await second.timeout(const Duration(seconds: 3));
    expect(response.statusCode, 200);
    expect(adapter.calls, 2);
  });
}
