// 网络核心的端到端冒烟测试：直接加载本机编出的动态库，经 FFI 发真实 HTTPS 请求。
//
// 依赖外网与 `core/net_core` 的 cargo 产物，默认跳过。手动运行：
//   (cd core/net_core && cargo build)
//   FLUXDO_LIVE=1 dart tool/flutterw.dart test test/services/network/core/net_core_live_test.dart
@TestOn('mac-os || linux || windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_http_adapter.dart';
import 'package:fluxdo/services/network/core/net_core_bindings.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';

void main() {
  final skip = Platform.environment['FLUXDO_LIVE'] == '1'
      ? false
      : '设置 FLUXDO_LIVE=1 才运行（依赖外网与本机 cargo 产物）';

  late Dio dio;

  setUpAll(() async {
    if (skip != false) return;
    final started = await NetCoreService.instance.start(const NetCoreConfig());
    expect(started, isTrue, reason: NetCoreService.instance.lastError);
    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = NetCoreHttpAdapter();
  });

  tearDownAll(() async {
    if (skip != false) return;
    await NetCoreService.instance.stop();
  });

  test('同域名 8 个冷并发请求共享一条 HTTP/2 连接', () async {
    final bindings = NetCoreBindings.instance;
    bindings.resetConnections();
    final before =
        jsonDecode(bindings.statusJson()!)['established_connections'] as int;
    final responses = await Future.wait(
      List.generate(
        8,
        (_) => dio.get<String>('https://www.cloudflare.com/cdn-cgi/trace'),
      ),
    );
    expect(responses.every((r) => r.statusCode == 200), isTrue);
    final after =
        jsonDecode(bindings.statusJson()!)['established_connections'] as int;
    expect(after - before, 1);
  }, skip: skip);

  test('清池后的新连接恢复 TLS 会话，响应带出连接信息', () async {
    const url = 'https://www.cloudflare.com/cdn-cgi/trace';
    await dio.get<String>(url);
    NetCoreBindings.instance.resetConnections();
    final response = await dio.get<String>(url);
    final connection =
        response.extra[netCoreConnectionExtraKey] as Map<String, dynamic>;
    expect(connection['reused'], isFalse);
    expect(connection['tlsResumed'], isTrue);
    expect(response.extra[HttpClientAdapter.extraKeyHttpVersion], '2.0');
  }, skip: skip);

  test('GET 拿到状态码、响应头与完整响应体', () async {
    final response = await dio.get<String>(
      'https://www.cloudflare.com/cdn-cgi/trace',
    );
    expect(response.statusCode, 200);
    expect(response.headers.value('content-type'), contains('text/plain'));
    expect(response.data, contains('h='));
  }, skip: skip);

  test('br/gzip 压缩响应在核心内解压', () async {
    final response = await dio.get<String>(
      'https://linux.do/srv/status',
      options: Options(headers: {'accept-encoding': 'gzip, br'}),
    );
    // 被 CF 拦也会是可读 HTML；这里只验证不是压缩后的乱码
    expect(response.statusCode, isNonZero);
    expect(response.data, isNot(contains('\u0000')));
  }, skip: skip);

  test('POST 请求体经流式写入送达上游', () async {
    final payload = {'hello': 'fluxdo', 'n': List.filled(4000, 'x').join()};
    final response = await dio.post<Map<String, dynamic>>(
      'https://postman-echo.com/post',
      data: jsonEncode(payload),
      options: Options(contentType: 'application/json'),
    );
    expect(response.statusCode, 200);
    expect(response.data?['json'], payload);
  }, skip: skip);

  test('流式响应可在中途放弃，不挂起', () async {
    final cancel = CancelToken();
    final response = await dio.get<ResponseBody>(
      'https://postman-echo.com/stream/50',
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancel,
    );
    // 核心会把已到手的相邻块并成一次回调，块数取决于网络时序，这里只验证能读到并放弃
    var bytes = 0;
    await for (final Uint8List chunk in response.data!.stream) {
      bytes += chunk.length;
      break;
    }
    expect(bytes, greaterThan(0));
  }, skip: skip);

  test('连接失败映射成 DioException 而不是挂起', () async {
    await expectLater(
      dio.get<String>('https://nonexistent.invalid/'),
      throwsA(isA<DioException>()),
    );
  }, skip: skip);
}
