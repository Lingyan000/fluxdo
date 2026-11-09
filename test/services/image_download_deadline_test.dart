import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('头像排队消耗调用预算，到期不再进入适配器且不占用槽位', () async {
    final adapter = _PendingImages();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioHttpClient.withClients(dio, dio);
    final parents = List.generate(6, (_) => CancelToken());
    final held = [
      for (var i = 0; i < 6; i++)
        client
            .fetchBytes(
              Uri.parse('https://cdn.test/held$i'),
              channel: DownloadChannel.avatar,
              cancellation: parents[i],
            )
            .then<void>((_) {}, onError: (_) {}),
    ];
    try {
      await adapter.sixStarted.future.timeout(const Duration(seconds: 2));
      await expectLater(
        client.fetchBytes(
          Uri.parse('https://cdn.test/queued'),
          channel: DownloadChannel.avatar,
          callTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(adapter.paths, isNot(contains('/queued')));
    } finally {
      for (final token in parents) {
        token.cancel();
      }
      await Future.wait(held);
    }
    expect(
      await client.fetchBytes(
        Uri.parse('https://cdn.test/ready'),
        channel: DownloadChannel.avatar,
      ),
      [1],
    );
    expect(adapter.paths, isNot(contains('/queued')));
    dio.close(force: true);
  });

  test('图片收到响应头后卡住，截止取消读取并释放下载槽', () async {
    final adapter = _PendingImages();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioHttpClient.withClients(dio, dio);
    final parent = CancelToken();
    await expectLater(
      client.fetchBytes(
        Uri.parse('https://cdn.test/body'),
        cancellation: parent,
        callTimeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<http.ClientException>()),
    );
    await adapter.bodyStopped.future.timeout(const Duration(seconds: 1));
    expect(adapter.cancelled, contains('/body'));
    expect(parent.isCancelled, isFalse);
    expect(await client.fetchBytes(Uri.parse('https://cdn.test/ready')), [1]);
    dio.close(force: true);
  });
}

class _PendingImages implements HttpClientAdapter {
  final paths = <String>[];
  final cancelled = <String>[];
  final sixStarted = Completer<void>();
  final bodyStopped = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    paths.add(path);
    if (paths.length == 6) sixStarted.complete();
    if (path == '/ready') return ResponseBody.fromBytes([1], 200);
    final body = StreamController<Uint8List>();
    cancelFuture?.then((_) {
      cancelled.add(path);
      body.close();
      if (path == '/body') bodyStopped.complete();
    });
    return ResponseBody(body.stream, 200);
  }

  @override
  void close({bool force = false}) {}
}
