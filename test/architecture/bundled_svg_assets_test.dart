import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jovial_svg/jovial_svg.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('所有内置 SVG 均可按原路径从构建产物解码为 SI', () async {
    final assets = Directory('assets')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.svg'));
    expect(assets, isNotEmpty);

    for (final file in assets) {
      final key = file.path.replaceAll(r'\', '/');
      await expectLater(
        ScalableImage.fromSIAsset(rootBundle, key),
        completion(isA<ScalableImage>()),
        reason: '$key 应在 pubspec.yaml 中随目录编译为 SI',
      );
    }
  });
}
