import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_artwork_palette.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_task_icon.dart';
import 'package:fluxdo/services/blob_image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('取主体色时忽略透明像素和黑白底，小面积亮点不会覆盖主体', () {
    final pixels = Uint8List.fromList([
      for (var i = 0; i < 60; i++) ...[255, 255, 255, 255],
      for (var i = 0; i < 60; i++) ...[0, 0, 0, 255],
      for (var i = 0; i < 60; i++) ...[255, 0, 0, 0],
      for (var i = 0; i < 16; i++) ...[40, 120, 200, 255],
      ...[255, 0, 0, 255],
    ]);
    expect(
      MiniAppArtworkPalette.fromPixels(pixels),
      const Color.fromARGB(255, 40, 120, 200),
    );
    expect(
      MiniAppArtworkPalette.fromPixels(
        Uint8List.fromList([255, 255, 255, 255, 60, 60, 60, 255]),
      ),
      isNull,
    );
    expect(MiniAppArtworkPalette.fromPixels(Uint8List(0)), isNull);
  });

  test('缓存中的 PNG 和非零 viewBox SVG 均可取色，损坏图标安全兜底', () async {
    final cache = await Directory.systemTemp.createTemp('mini-app-artwork-');
    await BlobImageCache.configureForTesting(root: cache);
    addTearDown(() async {
      await BlobImageCache.configureForTesting();
      final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final cachePath = await cache.resolveSymbolicLinks();
      expect(
        cachePath.startsWith('$tempRoot${Platform.pathSeparator}'),
        isTrue,
      );
      expect(
        cache.uri.pathSegments.where((v) => v.isNotEmpty).last,
        startsWith('mini-app-artwork-'),
      );
      await cache.delete(recursive: true);
    });
    final svgUrl = 'https://mini-app.test/palette.svg';
    await BlobImageCache.write(
      BlobImageCache.contentBucket,
      svgUrl,
      Uint8List.fromList(
        utf8.encode('''
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="50 40 80 80">
          <rect x="50" y="40" width="80" height="80" fill="#2878c8"/>
        </svg>
      '''),
      ),
    );
    final first = MiniAppArtworkPalette.resolve(svgUrl, Brightness.light);
    expect(
      MiniAppArtworkPalette.resolve(svgUrl, Brightness.light),
      same(first),
    );
    expect(await first, const Color(0xff2878c8));
    await _expectTaskIcon(svgUrl, const Color(0xff2878c8));

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 32, 32),
      Paint()..color = const Color(0xffd05040),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 32);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    const pngUrl = 'https://mini-app.test/palette.png';
    await BlobImageCache.write(
      BlobImageCache.contentBucket,
      pngUrl,
      png!.buffer.asUint8List(),
    );
    expect(
      await MiniAppArtworkPalette.resolve(pngUrl, Brightness.dark),
      const Color(0xffd05040),
    );
    await _expectTaskIcon(pngUrl, const Color(0xffd05040));

    // 横向图标按居中裁切，不应被压扁；非零 viewBox 仍应定位到中心。
    const wideUrl = 'https://mini-app.test/task-wide.svg';
    await BlobImageCache.write(
      BlobImageCache.contentBucket,
      wideUrl,
      Uint8List.fromList(
        utf8.encode('''
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="50 40 240 80">
          <rect x="50" y="40" width="240" height="80" fill="#ff0000"/>
          <rect x="130" y="40" width="80" height="80" fill="#2878c8"/>
        </svg>
      '''),
      ),
    );
    await _expectTaskIcon(wideUrl, const Color(0xff2878c8));

    const brokenUrl = 'https://mini-app.test/broken.png';
    await BlobImageCache.write(
      BlobImageCache.contentBucket,
      brokenUrl,
      Uint8List.fromList([1, 2, 3]),
    );
    expect(
      await MiniAppArtworkPalette.resolve(brokenUrl, Brightness.light),
      isNull,
    );
    expect(await MiniAppArtworkPalette.resolve('', Brightness.light), isNull);
    expect(await MiniAppTaskIcon.load(brokenUrl, Brightness.light), isNull);
    expect(await MiniAppTaskIcon.load('', Brightness.light), isNull);
  });
}

Future<void> _expectTaskIcon(String url, Color color) async {
  // 无工具栏、无已挂载 Widget，也能获得可发送给 Android 的真实图片。
  final bytes = await MiniAppTaskIcon.load(url, Brightness.light);
  expect(bytes, isNotNull);
  expect(bytes!.length, lessThanOrEqualTo(65536));
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      expect(frame.image.width, 96);
      expect(frame.image.height, 96);
      final pixels = (await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      expect(pixels[3], 0, reason: '系统图标沿用应用图标的圆角');
      for (final x in [12, 48, 84]) {
        final offset = (48 * 96 + x) * 4;
        expect(
          Color.fromARGB(
            pixels[offset + 3],
            pixels[offset],
            pixels[offset + 1],
            pixels[offset + 2],
          ),
          color,
        );
      }
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
