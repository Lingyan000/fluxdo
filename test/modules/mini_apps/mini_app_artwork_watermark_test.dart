import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_artwork_watermark.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/widgets/content/discourse_image.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('mini-app-watermark-');
    await BlobImageCache.configureForTesting(root: cache);
  });

  tearDown(() async {
    await BlobImageCache.configureForTesting();
    await cache.delete(recursive: true);
  });

  for (final brightness in Brightness.values) {
    testWidgets('预烘焙水印与逐帧遮罩合成像素一致（${brightness.name}）', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final dark = brightness == Brightness.dark;
      final urls = await tester.runAsync(() async {
        const svgUrl = 'https://mini-app.test/watermark.svg';
        await BlobImageCache.write(
          BlobImageCache.contentBucket,
          svgUrl,
          Uint8List.fromList(
            utf8.encode('''
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">
              <rect width="100" height="60" fill="#2878c8"/>
              <circle cx="50" cy="30" r="24" fill="#f0a020"/>
            </svg>
          '''),
          ),
        );
        // 非方形位图，覆盖 cover 裁切。
        final recorder = ui.PictureRecorder();
        Canvas(recorder)
          ..drawRect(
            const Rect.fromLTWH(0, 0, 96, 64),
            Paint()..color = const Color(0xffd05040),
          )
          ..drawCircle(
            const Offset(48, 32),
            20,
            Paint()..color = const Color(0xff40a060),
          );
        final picture = recorder.endRecording();
        final image = await picture.toImage(96, 64);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        const pngUrl = 'https://mini-app.test/watermark.png';
        await BlobImageCache.write(
          BlobImageCache.contentBucket,
          pngUrl,
          png!.buffer.asUint8List(),
        );
        return [svgUrl, pngUrl];
      });

      final boundaries = [for (final _ in urls!) (GlobalKey(), GlobalKey())];
      Widget sample(GlobalKey key, Widget child) => RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xff303030),
          child: SizedBox.square(dimension: 144, child: child),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Wrap(
            children: [
              for (final (index, url) in urls.indexed) ...[
                sample(
                  boundaries[index].$1,
                  _ReferenceWatermark(url: url, dark: dark),
                ),
                sample(
                  boundaries[index].$2,
                  MiniAppArtworkWatermark(url: url, size: 144),
                ),
              ],
            ],
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(
        find.descendant(
          of: find.byType(MiniAppArtworkWatermark),
          matching: find.byType(RawImage),
        ),
        findsNWidgets(urls.length),
      );

      for (final (reference, baked) in boundaries) {
        final expected = await _pixels(tester, reference);
        final actual = await _pixels(tester, baked);
        var max = 0;
        var covered = 0;
        for (var i = 0; i < expected.length; i++) {
          max = (expected[i] - actual[i]).abs() > max
              ? (expected[i] - actual[i]).abs()
              : max;
        }
        for (var i = 0; i < actual.length; i += 4) {
          if (actual[i] != 0x30) covered++;
        }
        expect(covered, greaterThan(1000), reason: '水印确实绘制出来');
        expect(max, lessThanOrEqualTo(2), reason: '仅允许取整误差');
      }
      // 参考实现的 SVG 尺寸记忆有 2 秒防抖保存。
      await tester.pump(const Duration(seconds: 3));
    });
  }
}

/// 改造前的绘制方式：每帧在图标上做一次渐变遮罩合成。
class _ReferenceWatermark extends StatelessWidget {
  const _ReferenceWatermark({required this.url, required this.dark});
  final String url;
  final bool dark;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [
        Colors.white.withValues(alpha: dark ? .16 : .10),
        Colors.transparent,
      ],
      stops: const [.05, .85],
    ).createShader(rect),
    child: DiscourseImage(
      url: url,
      width: 144,
      height: 144,
      fit: BoxFit.cover,
      placeholderBuilder: (_) => const SizedBox.shrink(),
      errorBuilder: (_) => const SizedBox.shrink(),
    ),
  );
}

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  final render =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 2);
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}
