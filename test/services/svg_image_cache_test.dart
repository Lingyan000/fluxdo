import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/svg_image_cache.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:material_ui/material_ui.dart';

const _small = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect width="10" height="10" fill="#2878c8"/>
</svg>
''';

/// 超过后台解析门槛的多路径 SVG。
String _large() {
  final random = Random(7);
  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">',
  );
  for (var i = 0; i < 60; i++) {
    final color = random.nextInt(0xffffff).toRadixString(16).padLeft(6, '0');
    buffer.write('<path fill="#$color" fill-opacity=".7" d="M');
    buffer.write('${random.nextDouble() * 100} ${random.nextDouble() * 60}');
    for (var j = 0; j < 4; j++) {
      buffer.write(
        ' Q${random.nextDouble() * 100} ${random.nextDouble() * 60}'
        ' ${random.nextDouble() * 100} ${random.nextDouble() * 60}',
      );
    }
    buffer.write('Z"/>');
  }
  buffer.write('</svg>');
  return buffer.toString();
}

Future<Uint8List> _render(ScalableImage si) async {
  final recorder = ui.PictureRecorder();
  final viewport = si.viewport;
  final canvas = Canvas(recorder)
    ..scale(200 / viewport.width, 120 / viewport.height)
    ..translate(-viewport.left, -viewport.top);
  si.paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 120);
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SvgImageCache.clear);

  test('同源只解析一次，同步与异步入口共享结果', () async {
    final first = SvgImageCache.sync(_small);
    expect(SvgImageCache.sync(_small), same(first));
    expect(await SvgImageCache.load(_small), same(first));
    expect(SvgImageCache.peek(_small), same(first));
    expect(SvgImageCache.peek('$_small '), isNull, reason: '按源码寻址，不同源不串用');
  });

  test('并发加载合并，较大的源码在后台解析且与主线程解析逐像素一致', () async {
    final source = _large();
    expect(source.length, greaterThan(4 << 10));
    final loads = [SvgImageCache.load(source), SvgImageCache.load(source)];
    final results = await Future.wait(loads);
    expect(results[1], same(results[0]));
    final direct = ScalableImage.fromSvgString(source, warnF: (_) {});
    expect(results[0].viewport, direct.viewport);
    expect(await _render(results[0]), await _render(direct));
  });

  test('解析失败也缓存，重复构建不反复解析', () async {
    const broken = '<svg xmlns="http://www.w3.org/2000/svg"><path d="M';
    expect(() => SvgImageCache.sync(broken), throwsA(anything));
    expect(SvgImageCache.peek(broken), isNull);
    await expectLater(SvgImageCache.load(broken), throwsA(anything));
    expect(() => SvgImageCache.sync(broken), throwsA(anything));
  });
}
