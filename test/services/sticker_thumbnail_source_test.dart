import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:fluxdo/services/sticker_thumbnail_source.dart';

import 'avif_sequence_still_test.dart' show AvifFixture;

/// 代理按预设状态码应答;源站按路径出文件,支持 Range。
class _FakeNetwork implements HttpClientAdapter {
  final files = <String, Uint8List>{};
  int proxyStatus = 200;
  bool honorRange = true;
  final requests = <String>[];

  /// 最小的 WebP 头(RIFF....WEBP),代理成功响应用它。
  static final proxyBody = Uint8List.fromList([
    ...'RIFF'.codeUnits,
    0,
    0,
    0,
    0,
    ...'WEBP'.codeUnits,
  ]);
  Uint8List? proxyOverride;

  int count(bool Function(String) test) => requests.where(test).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final range = options.headers['Range'] as String?;
    requests.add('${uri.host}${uri.path}${range == null ? '' : ' $range'}');
    if (uri.host == 'wsrv.nl') {
      return ResponseBody.fromBytes(
        proxyStatus == 200 ? (proxyOverride ?? proxyBody) : [0],
        proxyStatus,
      );
    }
    final file = files[uri.path];
    if (file == null) return ResponseBody.fromBytes([0], 404);
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
    if (match == null || !honorRange) {
      return ResponseBody.fromBytes(file, 200);
    }
    final start = int.parse(match.group(1)!);
    final end = [
      int.parse(match.group(2)!),
      file.length - 1,
    ].reduce((a, b) => a < b ? a : b);
    return ResponseBody.fromBytes(
      file.sublist(start, end + 1),
      206,
      headers: {
        'content-range': ['bytes $start-$end/${file.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bucket = BlobImageCache.stickerOriginalBucket;
  const host = 'https://cdn.example.com';
  late Directory root;
  late _FakeNetwork network;

  Future<Uint8List> fetch(String path, {String? displayPath}) =>
      StickerThumbnailSource.fetch(
        bucket: bucket,
        url: '$host$path',
        displayUrl: displayPath == null ? null : '$host$displayPath',
        targetSize: 160,
        priority: () => DownloadPriority.normal,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker-thumb-source-');
    network = _FakeNetwork();
    final dio = Dio()..httpClientAdapter = network;
    final client = DioHttpClient.withClients(dio, dio);
    await BlobImageCache.configureForTesting(root: root, client: client);
    StickerThumbnailSource.resetForTesting(client: client);
  });

  tearDown(() async {
    StickerThumbnailSource.resetForTesting();
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  test('代理成功时不下载原图', () async {
    network.files['/a.jpeg'] = Uint8List(5000);

    final bytes = await fetch('/a.jpeg');

    expect(bytes, _FakeNetwork.proxyBody);
    expect(network.count((r) => r.startsWith('cdn.example.com')), 0);
  });

  test('代理返回非图片内容时回退原图', () async {
    network.files['/a.jpeg'] = Uint8List(50);
    network.proxyOverride = Uint8List.fromList('<html>'.codeUnits);

    expect((await fetch('/a.jpeg')).length, 50);
  });

  test('displayUrl 与原图不同时交给代理的是 displayUrl', () async {
    network.files['/big.jpeg'] = Uint8List(5000);
    network.files['/small.jpeg'] = Uint8List(10);
    StickerThumbnailSource.proxyEnabled = false;

    final bytes = await fetch('/big.jpeg', displayPath: '/small.jpeg');

    expect(bytes.length, 10);
    expect(network.requests, ['cdn.example.com/small.jpeg']);
  });

  test('代理处理不了的动画 AVIF 改为 Range 取首帧', () async {
    final fixture = AvifFixture(mdatPayload: 200 * 1024);
    final file = fixture.build();
    network.files['/anim.avif'] = file;
    network.proxyStatus = 404;

    final bytes = await fetch('/anim.avif');

    final end = fixture.mdatOffset + 8 + 300;
    expect(bytes.length, end);
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'avif');
    // 只发了一次 64KB 的探测请求,没有下载整个文件
    expect(network.requests.last, 'cdn.example.com/anim.avif bytes=0-65535');
    expect(network.count((r) => r == 'cdn.example.com/anim.avif'), 0);
  });

  test('首帧超出探测范围时补一段 Range', () async {
    final fixture = AvifFixture(
      items: const [(70 * 1024, 4096)],
      mdatPayload: 200 * 1024,
    );
    network.files['/anim.avif'] = fixture.build();
    StickerThumbnailSource.proxyEnabled = false;

    final bytes = await fetch('/anim.avif');

    final end = fixture.mdatOffset + 8 + 70 * 1024 + 4096;
    expect(bytes.length, end);
    expect(network.requests, [
      'cdn.example.com/anim.avif bytes=0-65535',
      'cdn.example.com/anim.avif bytes=65536-${end - 1}',
    ]);
  });

  test('静态 AVIF 补齐剩余部分并写入原图缓存', () async {
    final file = AvifFixture(
      majorBrand: 'avif',
      compatibleBrands: const ['avif', 'mif1'],
      withMoov: false,
      mdatPayload: 100 * 1024,
    ).build();
    network.files['/still.avif'] = file;
    StickerThumbnailSource.proxyEnabled = false;

    final bytes = await fetch('/still.avif');

    expect(bytes, file);
    expect(await BlobImageCache.read(bucket, '$host/still.avif'), file);
    // 再取一次直接命中缓存
    network.requests.clear();
    expect(await fetch('/still.avif'), file);
    expect(network.requests, isEmpty);
  });

  test('源站忽略 Range 时直接用完整响应', () async {
    final file = AvifFixture(mdatPayload: 100 * 1024).build();
    network.files['/anim.avif'] = file;
    network.honorRange = false;
    StickerThumbnailSource.proxyEnabled = false;

    expect(await fetch('/anim.avif'), file);
  });

  test('代理 404 只跳过这张图,其它图照常走代理', () async {
    network.files['/a.jpeg'] = Uint8List(50);
    network.files['/b.jpeg'] = Uint8List(60);
    network.proxyStatus = 404;

    expect((await fetch('/a.jpeg')).length, 50);
    network.proxyStatus = 200;
    expect(await fetch('/b.jpeg'), _FakeNetwork.proxyBody);
    // a 不再尝试代理(清掉原图缓存,确认不是被缓存挡住的)
    await BlobImageCache.clearBucket(bucket);
    network.requests.clear();
    await fetch('/a.jpeg');
    expect(network.count((r) => r.startsWith('wsrv.nl')), 0);
  });

  test('代理限流后暂停使用', () async {
    network.files['/a.jpeg'] = Uint8List(50);
    network.files['/b.jpeg'] = Uint8List(60);
    network.proxyStatus = 429;

    expect((await fetch('/a.jpeg')).length, 50);
    network.proxyStatus = 200;
    expect((await fetch('/b.jpeg')).length, 60);
    expect(network.count((r) => r.startsWith('wsrv.nl')), 1);
  });

  test('代理连续三次服务端错误后暂停使用', () async {
    for (final name in ['a', 'b', 'c', 'd']) {
      network.files['/$name.jpeg'] = Uint8List(10);
    }
    network.proxyStatus = 502;

    for (final name in ['a', 'b', 'c', 'd']) {
      await fetch('/$name.jpeg');
    }

    expect(network.count((r) => r.startsWith('wsrv.nl')), 3);
  });

  test('解析 content-range', () {
    expect(StickerThumbnailSource.parseContentRange('bytes 0-65535/181106'), (
      0,
      65535,
      181106,
    ));
    expect(StickerThumbnailSource.parseContentRange('bytes 10-19/*'), (
      10,
      19,
      null,
    ));
    expect(StickerThumbnailSource.parseContentRange('bytes */100'), isNull);
    expect(StickerThumbnailSource.parseContentRange(null), isNull);
  });
}
