import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo_ocr/fluxdo_ocr.dart';
import 'package:image/image.dart' as img;

void main() {
  const OcrModelPaths paths = (
    detector: 'detector',
    recognizer: 'reader',
    config: 'config',
  );

  test('带取消令牌的识字任务能够进入工作线程并报告无效图片', () async {
    final service = LocalOcrService();
    addTearDown(service.dispose);
    await expectLater(
      service.recognize(
        Uint8List.fromList([1, 2, 3]),
        paths,
        cancelToken: CancelToken(),
      ),
      throwsFormatException,
    );
  });

  test('已取消的识字任务不再启动推理', () async {
    final service = LocalOcrService();
    addTearDown(service.dispose);
    final token = CancelToken()..cancel();
    await expectLater(
      service.recognize(Uint8List(0), paths, cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          '取消类型',
          DioExceptionType.cancel,
        ),
      ),
    );
  });

  group('LocalOcrService 宽度分桶与按桶排序', () {
    test('bucketRecognitionWidth 收敛到固定宽度桶', () {
      expect(LocalOcrService.bucketRecognitionWidth(1), 320);
      expect(LocalOcrService.bucketRecognitionWidth(320), 320);
      expect(LocalOcrService.bucketRecognitionWidth(321), 480);
      expect(LocalOcrService.bucketRecognitionWidth(480), 480);
      expect(LocalOcrService.bucketRecognitionWidth(500), 640);
      expect(LocalOcrService.bucketRecognitionWidth(700), 960);
      expect(LocalOcrService.bucketRecognitionWidth(1100), 1280);
      expect(LocalOcrService.bucketRecognitionWidth(1400), 1600);
      expect(LocalOcrService.bucketRecognitionWidth(2400), 1600);
    });

    test('无优先点时按宽度桶分组并保持桶内阅读顺序', () {
      // height=48 时宽度直接对应 lineWidth
      final boxes = <Rect>[
        const Rect.fromLTWH(0, 0, 700, 48), // bucket 960 (idx 0)
        const Rect.fromLTWH(0, 60, 200, 48), // bucket 320 (idx 1)
        const Rect.fromLTWH(0, 120, 720, 48), // bucket 960 (idx 2)
        const Rect.fromLTWH(0, 180, 180, 48), // bucket 320 (idx 3)
        const Rect.fromLTWH(0, 240, 400, 48), // bucket 480 (idx 4)
      ];
      final order = LocalOcrService.planRecognitionOrder(boxes);
      expect(order, [1, 3, 4, 0, 2]);
    });

    test('有优先点时首行最先且同桶行紧随其后，最小化张量重分配', () {
      final boxes = <Rect>[
        const Rect.fromLTWH(0, 0, 200, 48), // bucket 320 (idx 0)
        const Rect.fromLTWH(0, 60, 700, 48), // bucket 960 (idx 1)
        const Rect.fromLTWH(0, 120, 400, 48), // bucket 480 (idx 2)
        const Rect.fromLTWH(0, 180, 750, 48), // bucket 960 (idx 3)
        const Rect.fromLTWH(0, 240, 260, 48), // bucket 320 (idx 4)
      ];
      final order = LocalOcrService.planRecognitionOrder(boxes, priorityIdx: 3);
      // 先 idx 3 (960)，紧接着同桶 idx 1 (960)，然后按桶升序 320(0,4) -> 480(2)
      expect(order, [3, 1, 0, 4, 2]);
    });
  });

  group('LocalOcrService LUT 预处理与内联白底 Alpha 合成', () {
    test('检测与识别模式归一化精度与原公式一致，半透明像素按白底合成', () {
      final image = img.Image(width: 2, height: 1, numChannels: 4);
      // 像素 0：不透明纯红 (255, 0, 0, 255)
      image.setPixelRgba(0, 0, 255, 0, 0, 255);
      // 像素 1：50% 透明黑色 (0, 0, 0, 128) → 白底合成后约 (127, 127, 127)
      image.setPixelRgba(1, 0, 0, 0, 0, 128);

      final det = LocalOcrService.debugNormalizePixels(
        image,
        2,
        detection: true,
      );
      expect(det.length, 6);
      // BGR 平面：pixel 0 -> B=0, G=0, R=255
      expect(det[0], closeTo((0 / 255 - 0.485) / 0.229, 1e-5));
      expect(det[2], closeTo((0 / 255 - 0.456) / 0.224, 1e-5));
      expect(det[4], closeTo((255 / 255 - 0.406) / 0.225, 1e-5));
      // pixel 1 -> blended ~127
      expect(det[1], closeTo((127 / 255 - 0.485) / 0.229, 1e-5));

      final rec = LocalOcrService.debugNormalizePixels(
        image,
        4,
        detection: false,
      );
      // width=4 > img.width=2，右侧填充列应保持 0.0
      expect(rec.length, 12);
      expect(rec[0], closeTo(0 / 127.5 - 1.0, 1e-5)); // B=0
      expect(rec[4], closeTo(0 / 127.5 - 1.0, 1e-5)); // G=0
      expect(rec[8], closeTo(255 / 127.5 - 1.0, 1e-5)); // R=255
      expect(rec[2], 0.0);
      expect(rec[3], 0.0);
    });
  });

  group('LocalOcrService CTC 解码与默认线程数', () {
    test('CTC argmax 正确去重、去 blank 并计算字符水平坐标', () {
      const dict = ['', 'A', 'B', 'C'];
      // 4 步：step0='A', step1='A', step2=blank, step3='C'
      final scores = Float32List.fromList([
        0.1, 0.9, 0.0, 0.0, // A
        0.1, 0.8, 0.0, 0.0, // A (merged)
        0.9, 0.1, 0.0, 0.0, // blank
        0.1, 0.0, 0.2, 0.95, // C
      ]);
      final tokens = LocalOcrService.debugDecodeTokens(
        scores,
        4,
        dict,
        400,
        0,
        400,
      );
      expect(tokens.length, 2);
      expect(tokens[0].text, 'A');
      expect(tokens[0].leftPx, closeTo(0, 1e-6));
      expect(tokens[0].rightPx, closeTo(200, 1e-6));
      expect(tokens[1].text, 'C');
      expect(tokens[1].leftPx, closeTo(300, 1e-6));
      expect(tokens[1].rightPx, closeTo(400, 1e-6));
    });

    test('OcrInferenceModel.defaultThreads 在合理范围内', () {
      final threads = OcrInferenceModel.defaultThreads();
      expect(threads, greaterThanOrEqualTo(2));
      expect(threads, lessThanOrEqualTo(6));
    });
  });
}
