import 'dart:async';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';
import 'package:fluxdo/services/network/interceptors/network_log_interceptor.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';

class Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    200,
    headers: {
      'set-cookie': ['theme=dark; Path=/'],
    },
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('逻辑耗时包含早于网络日志拦截器的等待', () async {
    final dio = DeadlineDio(BaseOptions(), const Duration(seconds: 5))
      ..httpClientAdapter = Adapter();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          handler.next(options);
        },
      ),
    );
    dio.interceptors.add(NetworkLogInterceptor());
    final response = await dio.get<dynamic>('https://linux.do');
    final total = DeadlineDio.elapsedMilliseconds(response.requestOptions)!;
    expect(total, greaterThanOrEqualTo(35));
    expect(
      response.requestOptions.extra['_networkLog_preRequestMs'],
      greaterThanOrEqualTo(35),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(DeadlineDio.elapsedMilliseconds(response.requestOptions), total);
    dio.close();
  });
  test('原生响应先落入 jar，浏览器同步交由合并入口执行', () async {
    final jar = CookieJar();
    final scheduled = <String>[];
    final dio = Dio()..httpClientAdapter = Adapter();
    dio.interceptors.add(
      AppCookieManager(
        jar,
        scheduleWebViewSync: (url, names) {
          scheduled.addAll(names);
        },
      ),
    );
    await dio.get<dynamic>('https://linux.do');
    expect(
      (await jar.loadForRequest(Uri.parse('https://linux.do'))).single.value,
      'dark',
    );
    expect(scheduled, ['theme']);
    dio.close();
  });
}
