import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';

// 大模型不入库。转换后传入 --dart-define=FLUXDO_OCR_TEST_MODEL_DIR=<目录> 运行。
const _models = String.fromEnvironment('FLUXDO_OCR_TEST_MODEL_DIR');

void main() {
  group('真实 LiteRT OCR 模型', skip: _models.isEmpty, () {
    late OcrModelStore store;
    late OcrModelPaths paths;
    setUpAll(() async {
      store = OcrModelStore(
        dio: Dio(),
        directory: () async => Directory(_models),
      );
      paths = await store.paths();
    });
    tearDownAll(() => store.dispose());

    test('发布产物与应用固定摘要一致', () async {
      expect(await store.isReady(), isTrue);
      expect(
        await store.installedBytes(),
        greaterThanOrEqualTo(OcrModelStore.downloadBytes),
      );
    });

    for (final name in ['sample', 'long', 'wide', 'alpha']) {
      test('离线识字与字符坐标 $name', () async {
        final result = await LocalOcrService().recognizeDetailed(
          await File('test/fixtures/ocr/$name.png').readAsBytes(),
          paths,
        );
        for (final line in result.lines) {
          expect(line.charBounds.length, line.text.length);
          expect(line.bounds.isEmpty, isFalse);
          for (final box in line.charBounds) {
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(result.imageWidth));
            expect(box.top, greaterThanOrEqualTo(0));
            expect(box.bottom, lessThanOrEqualTo(result.imageHeight));
          }
        }
        final text = result.plainText;
        if (name == 'sample') {
          expect(text, contains('Hello world 123'));
          expect(text, contains('图片识别测试'));
        } else if (name == 'long') {
          for (var i = 0; i < 5; i++) {
            expect('Line $i'.allMatches(text), hasLength(1));
          }
        } else if (name == 'wide') {
          expect(text, contains('12345'));
          expect(text, contains('67890'));
          expect(text, contains('Goodbye world'));
        } else {
          expect(text, contains('透明图片识别'));
          expect(text, contains('Hello 123'));
        }
      });
    }
  });
}
