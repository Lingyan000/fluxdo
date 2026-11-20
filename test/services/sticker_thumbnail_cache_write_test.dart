import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/android_avif_decoder.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:fluxdo/services/sticker_thumbnail_provider.dart';
import 'package:fluxdo/services/sticker_thumbnail_source.dart';
import 'package:fluxdo/utils/scroll_busy_signal.dart';

/// 按路径出文件的源站。
class _Files implements HttpClientAdapter {
  final files = <String, Uint8List>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final file = files[options.uri.path];
    return file == null
        ? ResponseBody.fromBytes([0], 404)
        : ResponseBody.fromBytes(file, 200);
  }

  @override
  void close({bool force = false}) {}
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 结构上像 AVIF 的字节(ftyp/avif),内容由模拟的原生通道「解码」。
final _fakeAvif = Uint8List.fromList([
  0, 0, 0, 16, ...'ftyp'.codeUnits, ...'avif'.codeUnits, 0, 0, 0, 0, //
  ...List.filled(64, 1),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const host = 'https://sticker-cache.invalid';
  const channel = MethodChannel('com.fluxdo/avif');
  late Directory root;
  late _Files files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker-cache-write-');
    files = _Files();
    final dio = Dio()..httpClientAdapter = files;
    final client = DioHttpClient.withClients(dio, dio);
    await BlobImageCache.configureForTesting(root: root, client: client);
    StickerThumbnailSource.resetForTesting(client: client);
    StickerThumbnailSource.proxyEnabled = false;
    StickerThumbnailProvider.cancelInflight();
  });

  tearDown(() async {
    AndroidAvifDecoder.debugAvailableOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerThumbnailSource.resetForTesting();
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  Future<Uint8List?> cachedThumb(String path) => BlobImageCache.read(
    BlobImageCache.stickerThumbBucket,
    'sticker_thumb:160:$host$path',
  );

  testWidgets('Android 原生解出的 AVIF 缩略图 PNG 原样写缓存', (tester) async {
    await tester.runAsync(() async {
      final thumbPng = await _png(120, 80);
      final calls = <Map<Object?, Object?>>[];
      AndroidAvifDecoder.debugAvailableOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.arguments as Map<Object?, Object?>);
            return {'png': thumbPng, 'width': 120, 'height': 80};
          });
      files.files['/a.png'] = _fakeAvif;

      await StickerThumbnailProvider.precache('$host/a.png', targetSize: 160);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls.single['maxDim'], 160);
      expect(calls.single['png'], true);
      expect(await cachedThumb('/a.png'), thumbPng);
    });
  });

  testWidgets('不超过目标尺寸的非 AVIF 原图直接当缓存,不重新编码', (tester) async {
    await tester.runAsync(() async {
      final small = await _png(100, 100);
      files.files['/small.png'] = small;

      await StickerThumbnailProvider.precache(
        '$host/small.png',
        targetSize: 160,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await cachedThumb('/small.png'), small);
    });
  });

  testWidgets('需要缩放重编码的缩略图:滚动中不写,停下后补写', (tester) async {
    await tester.runAsync(() async {
      files.files['/big.png'] = await _png(400, 300);
      ScrollBusySignal.touch();

      await StickerThumbnailProvider.precache('$host/big.png', targetSize: 160);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await cachedThumb('/big.png'), isNull, reason: '滚动中推迟写盘');

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final cached = await cachedThumb('/big.png');
      expect(cached, isNotNull);
      final codec = await ui.instantiateImageCodec(cached!);
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (160, 120));
    });
  });

  testWidgets('原生通道缺失时标记不可用并回落', (tester) async {
    await tester.runAsync(() async {
      AndroidAvifDecoder.debugAvailableOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await AndroidAvifDecoder.decodePng(_fakeAvif, maxDim: 160),
        isNull,
      );
    });
  });
}
