import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';

/// 按路径返回预设状态码,记录每个路径的请求次数。
class _StatusImages implements HttpClientAdapter {
  final statuses = <String, int>{};
  final requests = <String, int>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests[path] = (requests[path] ?? 0) + 1;
    final status = statuses[path] ?? 200;
    return ResponseBody.fromBytes(status == 200 ? [7, 7] : [0], status);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bucket = BlobImageCache.emojiBucket;
  const primary = 'https://cdn.example.com/images/emoji/noto/cn.png?v=16';
  const fallback = 'https://cdn.example.com/images/emoji/twitter/cn.png?v=16';
  late Directory root;
  late _StatusImages adapter;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('blob-image-fallback-');
    adapter = _StatusImages();
    final dio = Dio()..httpClientAdapter = adapter;
    await BlobImageCache.configureForTesting(
      root: root,
      client: DioHttpClient.withClients(dio, dio),
    );
  });

  tearDown(() async {
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  test('主地址 404 取回退地址,之后不再请求主地址', () async {
    adapter.statuses['/images/emoji/noto/cn.png'] = 404;

    final first = await BlobImageCache.fetch(
      bucket,
      primary,
      fallbackUrl: fallback,
    );
    expect(first, [7, 7]);

    final second = await BlobImageCache.fetch(
      bucket,
      primary,
      fallbackUrl: fallback,
    );
    expect(second, [7, 7]);
    expect(adapter.requests['/images/emoji/noto/cn.png'], 1);
  });

  test('非 404 错误不回退', () async {
    adapter.statuses['/images/emoji/noto/cn.png'] = 500;

    await expectLater(
      BlobImageCache.fetch(bucket, primary, fallbackUrl: fallback),
      throwsA(
        isA<HttpStatusException>().having((e) => e.statusCode, 'status', 500),
      ),
    );
    expect(adapter.requests['/images/emoji/twitter/cn.png'], isNull);
  });

  test('主地址可用时不碰回退地址', () async {
    final bytes = await BlobImageCache.fetch(
      bucket,
      primary,
      fallbackUrl: fallback,
    );
    expect(bytes, [7, 7]);
    expect(adapter.requests['/images/emoji/twitter/cn.png'], isNull);
  });
}
