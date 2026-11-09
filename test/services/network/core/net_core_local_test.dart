// 真实 FFI + 本地 HTTP 服务，避免上游限流影响取消、超时和字节完整性验证。
// FLUXDO_LIVE=1 dart tool/flutterw.dart test test/services/network/core/net_core_local_test.dart
@TestOn('mac-os || linux || windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:fluxdo/services/network/core/net_core_http_adapter.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';
import 'package:fluxdo/services/network/cookie/csrf_session_trace.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';
import 'package:fluxdo/services/network/interceptors/redirect_interceptor.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

void main() {
  final skip = Platform.environment['FLUXDO_LIVE'] != '1'
      ? '需要本机已编译核心，设置 FLUXDO_LIVE=1 运行'
      : false;
  late HttpServer server;
  late Directory templateDirectory;
  late Dio dio;
  final receivedSlow = StreamController<void>.broadcast();

  Future<void> serve(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case '/echo':
          final bytes = await request.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'length': bytes.length,
              'body': base64Encode(bytes),
              'cookie': request.headers.value('cookie'),
              'csrfTokens': request.headers['x-csrf-token'],
              'contentType': request.headers.contentType.toString(),
            }),
          );
        case '/redirect-small':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/path?redirected=true');
          request.response.contentLength = 2;
          request.response.write('ok');
        case '/cookies':
          request.response.headers.add('set-cookie', 'session=one; Path=/');
          request.response.headers.add('set-cookie', 'clearance=two; Path=/');
        case '/poll':
          await Future<void>.delayed(const Duration(seconds: 2));
          request.response.write('[]');
        case '/slow':
          receivedSlow.add(null);
          await Future<void>.delayed(const Duration(milliseconds: 800));
          request.response.write('done');
        case '/stream':
          request.response.headers.contentType = ContentType.binary;
          request.response.bufferOutput = false;
          for (var i = 0; i < 10; i++) {
            request.response.add(List.filled(1024, i));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        case '/gzip':
          request.response.headers.set('content-encoding', 'gzip');
          request.response.add(gzip.encode(utf8.encode('压缩内容' * 100)));
        case '/delayed-body':
          request.response.bufferOutput = false;
          request.response.add([1]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          request.response.add([2]);
        case '/burst':
          request.response.add(
            List<int>.generate(8 * 1024 * 1024 + 17, (i) => i % 251),
          );
        default:
          request.response.write(request.uri.toString());
      }
      await request.response.close();
    } catch (_) {
      // 取消请求后服务端的写入失败属于预期。
    }
  }

  setUpAll(() async {
    if (skip != false) return;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(serve(request)));
    // 使用带小写自定义头顺序的浏览器模板，覆盖真实 FFI 的头部重排路径。
    templateDirectory = await Directory.systemTemp.createTemp(
      'fluxdo-header-template-',
    );
    final template = File('${templateDirectory.path}/template.json');
    await template.writeAsString(
      jsonEncode({
        'hello': jsonDecode(
          await File(
            'core/net_core/tests/fixtures/chrome156_linux_do_hello.json',
          ).readAsString(),
        ),
        'early_frames': [],
        'pseudo_order': [':method', ':authority', ':scheme', ':path'],
        'fetch_header_order': [
          'x-csrf-token',
          'x-requested-with',
          'cookie',
          'content-type',
        ],
        'accept_encoding': null,
      }),
    );
    expect(
      await NetCoreService.instance.start(
        NetCoreConfig(fingerprintCachePath: template.path),
      ),
      isTrue,
    );
  });
  setUp(() {
    if (skip != false) return;
    dio = Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:${server.port}',
        receiveTimeout: const Duration(seconds: 5),
      ),
    )..httpClientAdapter = NetCoreHttpAdapter();
  });
  tearDown(() {
    if (skip == false) dio.close(force: true);
  });
  tearDownAll(() async {
    if (skip != false) return;
    await server.close(force: true);
    await receivedSlow.close();
    await NetCoreService.instance.stop();
    await templateDirectory.delete(recursive: true);
  });

  test('HTTP 保留路径和查询参数', () async {
    final response = await dio.get<String>('/path?q=a%2Fb');
    expect(response.data, '/path?q=a%2Fb');
    final connection = response.extra[netCoreConnectionExtraKey] as Map;
    expect(connection['echApplied'], isFalse);
    expect(connection['echAccepted'], isFalse);
  }, skip: skip);
  test('大请求体完整送达，Cookie 原样传递', () async {
    final bytes = List<int>.generate(1024 * 1024, (i) => i % 256);
    final response = await dio.post<Map<String, dynamic>>(
      '/echo',
      data: Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += 4096)
          Uint8List.fromList(bytes.sublist(i, i + 4096)),
      ]),
      options: Options(headers: {'cookie': 'session=one; clearance=two'}),
    );
    expect(response.data?['length'], bytes.length);
    expect(response.data?['body'], base64Encode(bytes));
    expect(response.data?['cookie'], 'session=one; clearance=two');
  }, skip: skip);
  test('CSRF 请求经真实核心整理后关键头保持一致', () async {
    final response = await dio.post<Map<String, dynamic>>(
      '/echo',
      data: 'topic_id=1&topic_time=1000',
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'Cookie': '_forum_session=test%2Fsession; _t=test-login',
          'X-CSRF-Token': 'secret-token',
          'Origin': 'https://linux.do',
          'Referer': 'https://linux.do/',
        },
      ),
    );
    final trace =
        response.requestOptions.extra[CsrfSessionTrace.extraKey] as Map;
    final prepared = trace['corePreparedRequest'] as Map;
    expect(prepared['stage'], 'core-prepared-headers');
    expect(prepared['header_hashes'], trace['csrfInputHeaderHashes']);
    expect(
      response.data?['cookie'],
      '_forum_session=test%2Fsession; _t=test-login',
    );
    expect(response.data?['csrfTokens'], ['secret-token']);
    expect(
      utf8.decode(base64Decode(response.data!['body'] as String)),
      'topic_id=1&topic_time=1000',
    );
  }, skip: skip);
  test('超大单块上传分段后字节与诊断计数一致', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 17, (i) => i % 251),
    );
    final response = await dio.post<Map<String, dynamic>>(
      '/echo',
      data: Stream.value(bytes),
      options: Options(headers: {'X-CSRF-Token': 'test-token'}),
    );
    expect(response.data?['body'], base64Encode(bytes));
    final trace =
        response.requestOptions.extra[CsrfSessionTrace.extraKey] as Map;
    expect(trace['sentBodyBytes'], bytes.length);
    expect(trace['sentBodyChunks'], 17);
    expect(trace['sentBodyComplete'], isTrue);
  }, skip: skip);
  test('multipart 文件和字段完整送达', () async {
    final response = await dio.post<Map<String, dynamic>>(
      '/echo',
      data: FormData.fromMap({
        'description': '测试附件',
        'file': MultipartFile.fromBytes([0, 1, 2, 255], filename: 'sample.bin'),
      }),
    );
    final body = latin1.decode(base64Decode(response.data!['body'] as String));
    expect(
      response.data?['contentType'],
      startsWith('multipart/form-data; boundary='),
    );
    expect(body, contains('filename="sample.bin"'));
    expect(body, contains(latin1.decode([0, 1, 2, 255])));
    expect(body, contains(latin1.decode(utf8.encode('测试附件'))));
  }, skip: skip);
  test('空响应长轮询等待服务端返回，不提前重连', () async {
    final elapsed = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      expect((await dio.get<String>('/poll')).data, '[]');
    }
    expect(elapsed.elapsed, greaterThanOrEqualTo(const Duration(seconds: 6)));
  }, skip: skip);
  test('应用代理开启和关闭后出口正确切换', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    var tunnels = 0;
    proxy.listen((client) {
      sockets.add(client);
      final header = <int>[];
      late StreamSubscription<Uint8List> subscription;
      subscription = client.listen((chunk) async {
        header.addAll(chunk);
        final end = latin1.decode(header).indexOf('\r\n\r\n');
        if (end < 0) return;
        subscription.pause();
        expect(latin1.decode(header), startsWith('CONNECT '));
        tunnels++;
        final remote = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        sockets.add(remote);
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        await client.flush();
        if (header.length > end + 4) remote.add(header.sublist(end + 4));
        subscription.onData(remote.add);
        subscription.onDone(remote.destroy);
        subscription.onError((_) => remote.destroy());
        remote.listen(
          client.add,
          onDone: client.destroy,
          onError: (_) => client.destroy(),
        );
        subscription.resume();
      }, onError: (_) => client.destroy());
    });
    try {
      expect(
        await NetCoreService.instance.start(
          NetCoreConfig(
            upstreamProxy: ProxySettings(
              enabled: true,
              host: '127.0.0.1',
              port: proxy.port,
            ),
          ),
        ),
        isTrue,
      );
      expect((await dio.get<String>('/proxy')).data, '/proxy');
      expect(tunnels, greaterThan(0));
      final before = tunnels;
      expect(
        await NetCoreService.instance.start(const NetCoreConfig()),
        isTrue,
      );
      expect((await dio.get<String>('/direct')).data, '/direct');
      expect(tunnels, before);
    } finally {
      await NetCoreService.instance.start(const NetCoreConfig());
      for (final socket in sockets) {
        socket.destroy();
      }
      await proxy.close();
    }
  }, skip: skip);
  test('无效 TLS 证书被拒绝，失败后核心仍可请求', () async {
    final context = SecurityContext()
      ..useCertificateChain('core/net_core/certs/ca.crt')
      ..usePrivateKey('core/net_core/certs/ca.key');
    final secure = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    secure.listen((request) => unawaited(serve(request)), onError: (_) {});
    try {
      await expectLater(
        dio.get<String>(
          'https://127.0.0.1:${secure.port}/',
          options: Options(
            receiveTimeout: const Duration(seconds: 3),
            sendTimeout: const Duration(seconds: 3),
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect((await dio.get<String>('/alive')).data, '/alive');
    } finally {
      await secure.close(force: true);
    }
  }, skip: skip);
  test('重复 Set-Cookie 不合并或丢失', () async {
    final response = await dio.get<String>('/cookies');
    expect(response.headers['set-cookie'], [
      'session=one; Path=/',
      'clearance=two; Path=/',
    ]);
  }, skip: skip);
  test('gzip 解压后字节完整', () async {
    final response = await dio.get<String>('/gzip');
    expect(response.data, '压缩内容' * 100);
  }, skip: skip);
  test('GET 等响应头超时正确分类', () async {
    await expectLater(
      dio.get<String>(
        '/slow',
        options: Options(receiveTimeout: const Duration(milliseconds: 150)),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
  }, skip: skip);
  test('慢上传耗时不误算为接收超时', () async {
    Stream<Uint8List> upload() async* {
      for (var i = 0; i < 4; i++) {
        yield Uint8List.fromList([i]);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    final response = await dio.post<Map<String, dynamic>>(
      '/echo',
      data: upload(),
      options: Options(receiveTimeout: const Duration(milliseconds: 200)),
    );
    expect(response.data?['body'], base64Encode([0, 1, 2, 3]));
  }, skip: skip);
  test('POST 上传完成后等待响应头也受接收超时限制', () async {
    await expectLater(
      dio.post<String>(
        '/slow',
        data: 'body',
        options: Options(receiveTimeout: const Duration(milliseconds: 150)),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
  }, skip: skip);
  for (final withFirstChunk in [false, true]) {
    test('上传停滞返回 sendTimeout 并取消数据源：首块=$withFirstChunk', () async {
      final cancelled = Completer<void>();
      final source = StreamController<Uint8List>(
        onCancel: () => cancelled.complete(),
      );
      if (withFirstChunk) source.add(Uint8List.fromList([1, 2, 3]));
      try {
        await expectLater(
          dio.post<dynamic>(
            '/echo',
            data: source.stream,
            options: Options(sendTimeout: const Duration(milliseconds: 150)),
          ),
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.sendTimeout,
            ),
          ),
        );
        await cancelled.future.timeout(const Duration(seconds: 2));
        // 失败请求释放核心状态后，后续请求仍正常工作。
        expect(
          (await dio.get<String>('/after-timeout')).data,
          '/after-timeout',
        );
      } finally {
        unawaited(source.close());
      }
    }, skip: skip);
  }
  test('持续有数据的上传也受整个发送阶段时限约束', () async {
    Stream<Uint8List> upload() async* {
      for (var i = 0; i < 10; i++) {
        yield Uint8List.fromList([i]);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }

    await expectLater(
      dio.post<dynamic>(
        '/echo',
        data: upload(),
        options: Options(sendTimeout: const Duration(milliseconds: 250)),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.sendTimeout,
        ),
      ),
    );
  }, skip: skip);
  test('上传完成后等待响应不再消耗发送时限', () async {
    final response = await dio.post<String>(
      '/slow',
      data: 'ok',
      options: Options(
        sendTimeout: const Duration(milliseconds: 150),
        receiveTimeout: const Duration(seconds: 2),
      ),
    );
    expect(response.data, 'done');
  }, skip: skip);
  test('取消令牌中止尚未返回响应头的请求', () async {
    final token = CancelToken();
    final arrived = receivedSlow.stream.first.timeout(
      const Duration(seconds: 5),
    );
    final response = dio.get<String>('/slow', cancelToken: token);
    final assertion = expectLater(
      response,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await arrived;
    token.cancel();
    await assertion;
  }, skip: skip);

  test('逻辑截止经真实 FFI 中断慢响应体并关闭上游连接', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = Completer<void>();
    Socket? peer;
    final accept = listener.listen((socket) {
      peer = socket;
      var sent = false;
      final header = <int>[];
      socket.listen(
        (data) {
          header.addAll(data);
          if (!sent && latin1.decode(header).contains('\r\n\r\n')) {
            sent = true;
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nx');
          }
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object error) {
          if (!closed.isCompleted) closed.completeError(error);
        },
      );
    });
    final bounded = DeadlineDio(
      BaseOptions(),
      const Duration(milliseconds: 250),
    )..httpClientAdapter = NetCoreHttpAdapter();
    try {
      await expectLater(
        bounded.get<List<int>>(
          'http://127.0.0.1:${listener.port}/image',
          options: Options(responseType: ResponseType.bytes),
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'cause',
            isA<CallDeadlineExceeded>(),
          ),
        ),
      );
      await closed.future.timeout(const Duration(seconds: 2));
      expect((await dio.get<String>('/path')).data, '/path');
    } finally {
      bounded.close(force: true);
      peer?.destroy();
      await accept.cancel();
      await listener.close();
    }
  }, skip: skip);
  test('取消等待下一块数据的上传时立即取消数据源订阅', () async {
    final listened = Completer<void>();
    final cancelled = Completer<void>();
    final source = StreamController<Uint8List>(
      onListen: () => listened.complete(),
      onCancel: () => cancelled.complete(),
    );
    final token = CancelToken();
    final assertion = expectLater(
      dio.post<dynamic>('/echo', data: source.stream, cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    try {
      await listened.future.timeout(const Duration(seconds: 3));
      token.cancel('stop stalled source');
      await assertion;
      await cancelled.future.timeout(const Duration(seconds: 2));
    } finally {
      unawaited(source.close());
    }
  }, skip: skip);
  test('服务器提前拒绝上传后取消仍未结束的数据源', () async {
    final cancelled = Completer<void>();
    final source = StreamController<Uint8List>(
      onCancel: () => cancelled.complete(),
    );
    final earlyServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final sockets = <Socket>[];
    earlyServer.listen((socket) {
      sockets.add(socket);
      var replied = false;
      socket.listen((_) {
        if (replied) return;
        replied = true;
        // 只发响应头，响应体等取消订阅后再发，确保不是 DONE 才触发清理。
        socket.write(
          'HTTP/1.1 413 Content Too Large\r\nContent-Length: 2\r\n\r\n',
        );
      }, onError: (Object _) {});
    });
    try {
      final result = dio.post<dynamic>(
        'http://127.0.0.1:${earlyServer.port}/reject',
        data: source.stream,
        options: Options(
          headers: {'content-length': '1000000'},
          validateStatus: (_) => true,
        ),
      );
      source.add(Uint8List.fromList([1]));
      await cancelled.future.timeout(const Duration(seconds: 2));
      sockets.single.write('no');
      expect(
        (await result.timeout(const Duration(seconds: 3))).statusCode,
        413,
      );
    } finally {
      unawaited(source.close());
      for (final socket in sockets) {
        socket.destroy();
      }
      await earlyServer.close();
    }
  }, skip: skip);
  test('关闭一个适配器不取消另一个适配器的请求', () async {
    final other = Dio(BaseOptions(baseUrl: dio.options.baseUrl))
      ..httpClientAdapter = NetCoreHttpAdapter();
    final arrived = receivedSlow.stream.first.timeout(
      const Duration(seconds: 5),
    );
    final response = other.get<String>('/slow');
    await arrived;
    dio.close(force: true);
    expect((await response).data, 'done');
    other.close(force: true);
  }, skip: skip);
  test('强制关闭适配器会取消停滞的上传数据源', () async {
    final listened = Completer<void>();
    final cancelled = Completer<void>();
    final source = StreamController<Uint8List>(
      onListen: listened.complete,
      onCancel: cancelled.complete,
    );
    final assertion = expectLater(
      dio.post<dynamic>('/echo', data: source.stream),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    try {
      await listened.future.timeout(const Duration(seconds: 3));
      dio.close(force: true);
      await assertion;
      await cancelled.future.timeout(const Duration(seconds: 2));
    } finally {
      unawaited(source.close());
    }
  }, skip: skip);
  test('Dio 放弃错误响应体时关闭上游连接', () async {
    final rejected = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final disconnected = Completer<void>();
    final sockets = <Socket>[];
    void markDisconnected() {
      if (!disconnected.isCompleted) disconnected.complete();
    }

    rejected.listen((socket) {
      sockets.add(socket);
      unawaited(
        socket.done.then(
          (_) => markDisconnected(),
          onError: (Object _) => markDisconnected(),
        ),
      );
      var replied = false;
      socket.listen(
        (_) {
          if (replied) return;
          replied = true;
          socket.write(
            'HTTP/1.1 400 Bad Request\r\nContent-Length: 10\r\n\r\n',
          );
        },
        onDone: markDisconnected,
        onError: (Object _) => markDisconnected(),
      );
    });
    try {
      await expectLater(
        dio.get<dynamic>(
          'http://127.0.0.1:${rejected.port}/reject',
          options: Options(receiveDataWhenStatusError: false),
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.badResponse,
          ),
        ),
      );
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await rejected.close();
    }
  }, skip: skip);
  test('图片失败或消费中断后取消未读完的响应', () async {
    final images = DioHttpClient.withClients(dio, dio);
    for (final status in [403, 200]) {
      final peer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      final sockets = <Socket>[];
      void markDisconnected() {
        if (!disconnected.isCompleted) disconnected.complete();
      }

      peer.listen((socket) {
        sockets.add(socket);
        unawaited(
          socket.done.then(
            (_) => markDisconnected(),
            onError: (Object _) => markDisconnected(),
          ),
        );
        var replied = false;
        socket.listen(
          (_) {
            if (replied) return;
            replied = true;
            socket.write(
              'HTTP/1.1 $status Test\r\nContent-Length: 1000000\r\n\r\nx',
            );
          },
          onDone: markDisconnected,
          onError: (Object _) => markDisconnected(),
        );
      });
      try {
        final response = images.fetchBytes(
          Uri.parse('http://127.0.0.1:${peer.port}/image'),
          onProgress: status == 200
              ? (_, _) => throw StateError('consumer stopped')
              : null,
        );
        await expectLater(
          response,
          throwsA(
            status == 403 ? isA<http.ClientException>() : isA<StateError>(),
          ),
        );
        await disconnected.future.timeout(const Duration(seconds: 2));
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await peer.close();
      }
    }
  }, skip: skip);
  test('响应流暂停恢复后内容仍完整', () async {
    final response = await dio.get<ResponseBody>(
      '/stream',
      options: Options(responseType: ResponseType.stream),
    );
    final output = <int>[];
    await for (final chunk in response.data!.stream) {
      output.addAll(chunk);
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
    expect(output, [for (var i = 0; i < 10; i++) ...List.filled(1024, i)]);
  }, skip: skip);
  test('小重定向响应读完后下一跳复用真实连接', () async {
    dio.interceptors.add(RedirectInterceptor(dio));
    final response = await dio.get<ResponseBody>(
      '/redirect-small',
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    expect(
      await response.data!.stream.expand((b) => b).toList(),
      utf8.encode('/path?redirected=true'),
    );
    final hops =
        response.requestOptions.extra[RedirectInterceptor.hopsKey] as List;
    final finalConnection = response.extra[netCoreConnectionExtraKey] as Map;
    expect(finalConnection['reused'], true);
    expect(finalConnection['connectionId'], hops.single['connectionId']);
  }, skip: skip);
  test('完整 Dio 链延迟订阅不消耗接收时限', () async {
    final response = await dio.get<ResponseBody>(
      '/delayed-body',
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(milliseconds: 200),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await response.data!.stream.expand((chunk) => chunk).toList(), [
      1,
      2,
    ]);
  }, skip: skip);
  test('完整 Dio 链慢消费保留背压且不误报超时', () async {
    final response = await dio.get<ResponseBody>(
      '/stream',
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(milliseconds: 150),
      ),
    );
    final bytes = <int>[];
    await for (final chunk in response.data!.stream) {
      bytes.addAll(chunk);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(bytes, [for (var i = 0; i < 10; i++) ...List.filled(1024, i)]);
  }, skip: skip);
  test('响应体尚未订阅时不启动核心接收计时', () async {
    final body = await dio.httpClientAdapter.fetch(
      RequestOptions(
        path: '${dio.options.baseUrl}/delayed-body',
        receiveTimeout: const Duration(milliseconds: 200),
      ),
      null,
      null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await body.stream.expand((chunk) => chunk).toList(), [1, 2]);
  }, skip: skip);
  test('慢消费者暂停期间不消耗核心接收超时', () async {
    final body = await dio.httpClientAdapter.fetch(
      RequestOptions(
        path: '${dio.options.baseUrl}/stream',
        receiveTimeout: const Duration(milliseconds: 150),
      ),
      null,
      null,
    );
    final bytes = <int>[];
    await for (final chunk in body.stream) {
      bytes.addAll(chunk);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(bytes, [for (var i = 0; i < 10; i++) ...List.filled(1024, i)]);
  }, skip: skip);
  test('大响应跨多轮缓冲预算后内容完整且事件大小受限', () async {
    final body = await dio.httpClientAdapter.fetch(
      RequestOptions(path: '${dio.options.baseUrl}/burst'),
      null,
      null,
    );
    var received = 0;
    await for (final chunk in body.stream) {
      expect(chunk.length, lessThanOrEqualTo(256 * 1024));
      expect(
        chunk,
        List<int>.generate(chunk.length, (i) => (received + i) % 251),
      );
      received += chunk.length;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(received, 8 * 1024 * 1024 + 17);
  }, skip: skip);
}
