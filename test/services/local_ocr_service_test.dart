import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';

void main() {
  const OcrModelPaths paths = (
    detector: 'detector',
    recognizer: 'reader',
    config: 'config',
  );
  test('带取消令牌的识字任务能够进入工作线程并报告无效图片', () async {
    await expectLater(
      LocalOcrService().recognize(
        Uint8List.fromList([1, 2, 3]),
        paths,
        cancelToken: CancelToken(),
      ),
      throwsFormatException,
    );
  });

  test('已取消的识字任务不再启动推理', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      LocalOcrService().recognize(Uint8List(0), paths, cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          '取消类型',
          DioExceptionType.cancel,
        ),
      ),
    );
  });
}
