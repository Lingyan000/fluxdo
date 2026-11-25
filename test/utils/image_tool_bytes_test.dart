import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:fluxdo/utils/image_tool_bytes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('动图送入编辑和识字前只保留第一帧', () async {
    final first = img.Image(width: 8, height: 8);
    img.fill(first, color: img.ColorRgb8(255, 0, 0));
    final second = img.Image(width: 8, height: 8);
    img.fill(second, color: img.ColorRgb8(0, 0, 255));
    first.addFrame(second);
    final png = await ImageToolBytes.png(img.encodeGif(first));
    final decoded = img.decodePng(png)!;
    expect(decoded.numFrames, 1);
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 0).b, 0);
  });

  test('SVG 可以转换为带透明度的静态 PNG', () async {
    final source = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60">'
      '<rect x="10" y="10" width="30" height="20" fill="red"/></svg>',
    );
    final png = await ImageToolBytes.png(source);
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 100);
    expect(image.height, 60);
    image.dispose();
    codec.dispose();
  });
}
